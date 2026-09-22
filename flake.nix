{
  description = "we-layerd — native Wallpaper Engine runtime for Wayland (we-layerd daemon + we-gui)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      #
      # --- pinned upstream source -------------------------------------------------
      #
      # The workspace is two git repositories stitched together:
      #
      #   we-layerd (this Rust crate + apps/we-gui + crates/we-*)
      #     └─ third_party/wallpaper-engine-renderer  (C++ renderer, a submodule)
      #          └─ third_party/{Eigen,glslang,SPIRV-Reflect,quickjs,miniaudio,nlohmann}
      #
      # We fetch them separately so each hash is independent and the (slow, cross
      # host) recursive renderer submodule fetch is cached on its own. The renderer
      # is spliced into `third_party/wallpaper-engine-renderer` in preConfigure, and
      # `build-without-git-metadata.patch` makes the root build.rs skip its
      # `git submodule update --init --recursive` (impossible in the sandbox).
      #
      weLayerdRev = "ff118c553328d283aa46f86157da219816e68ab1"; # v0.2.8
      weLayerdSrc = nixpkgs.legacyPackages.x86_64-linux.fetchFromGitHub {
        owner = "Aromatic05";
        repo = "we-layerd";
        rev = weLayerdRev;
        # No submodules here: third_party/wallpaper-engine-renderer is fetched
        # separately (see below) and copied into the tree at build time.
        hash = "sha256-F+DoHbw1VFep3Sxm8eNXwC1yQv3D4TitF4WKrAVLcAo=";
      };

      # Submodule rev recorded by the root repo's tree at weLayerdRev.
      # v0.2.8 moved it 12dbc5eb -> 89dfcd86 (renderer staging-ownership fix),
      # so both pins must move together.
      rendererRev = "89dfcd86de2dc0ae537bc136046c5ed05733e7b7";
      rendererSrc = nixpkgs.legacyPackages.x86_64-linux.fetchFromGitHub {
        owner = "Aromatic05";
        repo = "wallpaper-engine-renderer";
        rev = rendererRev;
        # Recursive: Eigen/glslang/quickjs/... are renderer submodules the
        # CMake build compiles in-tree. nixpkgs fetchFromGitHub does a full
        # `git submodule update --init --recursive` for these.
        fetchSubmodules = true;
        hash = "sha256-nw11exZ+H1cFoibDKriAi3gQlxLaBmyjjtZNMWyvBIw=";
      };

      #
      # --- pinned binary tarballs (from package/common/versions.env) -------------
      #
      # These two prebuilt upstream distributions are intentionally *not* built
      # from source:
      #
      #   * CEF (Chromium Embedded Framework) — the official Spotify CDN minimal
      #     linux64 build. Used by the *web* wallpaper backend. CEF ships its own
      #     SwiftShader (libvk_swiftshader/libEGL/libGLESv2/libvulkan.so.1) so the
      #     web wallpaper's offscreen render never touches the host GPU.
      #   * DXC (Microsoft DirectX Shader Compiler) — the scene shader path is
      #     DXC-only. The renderer links `libdxcompiler.so`/`libdxil.so` and needs
      #     `dxc` on PATH at build time; at runtime DXC lives in a private rpath.
      #
      # SHA-256 digests are taken verbatim from `package/common/versions.env`.
      #
      cefArchive = nixpkgs.legacyPackages.x86_64-linux.fetchurl {
        url =
          "https://cef-builds.spotifycdn.com/cef_binary_144.0.30+g9e70dde+chromium-144.0.7559.257_linux64_minimal.tar.bz2";
        sha256 = "e0cd8d590c32da014633d27b9ee8d213a16c47ee563fee545033cb0895c989d7";
      };
      dxcArchive = nixpkgs.legacyPackages.x86_64-linux.fetchurl {
        url =
          "https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2602.24/linux_dxc_2026_05_26.x86_64.tar.gz";
        sha256 = "928b3e9986d11dc4279050e02340950c29bcbd1e5efb9d3ded9669dade37639d";
      };

      #
      # --- small helpers to turn tarballs into clean store "roots" ----------------
      #
      mkCefRoot = pkgs: pkgs.runCommand "cef-root" { } ''
        mkdir -p "$out"
        tar -xjf "${cefArchive}" -C "$out" --strip-components=1
        # CMake's FindCEF.cmake expects Release/libcef.so + cmake/ + include/ +
        # libcef_dll/ + Resources/. The Spotify "minimal" distribution ships all
        # of these; remove chrome-sandbox (setuid, irrelevant & undesirable).
        rm -f "$out/Release/chrome-sandbox"
      '';

      mkDxcRoot = pkgs: pkgs.runCommand "dxc-root" { } ''
        mkdir -p "$out"
        tar -xzf "${dxcArchive}" -C "$out" --strip-components=1
      '';

      # The set of GStreamer plugin packages the daemon needs at runtime for
      # video wallpapers (mirrors the RPM/DEB Requires list). We expose these
      # via GST_PLUGIN_SYSTEM_PATH_1_0 so the host gstreamer loader finds them
      # *without* bundling a single plugin (preserves host driver reuse).
      gstPlugins = pkgs: with pkgs.gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
        gst-plugins-ugly
        gst-libav
      ];

      buildPkg = { pkgs }:
        let
          cefRoot = mkCefRoot pkgs;
          dxcRoot = mkDxcRoot pkgs;
          gst = gstPlugins pkgs;

          # Colon-joined gstreamer plugin directories for the runtime wrapper.
          gstPluginDirs = pkgs.lib.concatStringsSep ":" (map (p: "${p}/lib/gstreamer-1.0") gst);

          inherit (pkgs) lib;
        in
        pkgs.rustPlatform.buildRustPackage rec {
          pname = "we-layerd";
          version = "0.2.8";

          src = weLayerdSrc;

          #
          # The root build.rs shells out to CMake to build the upstream C++
          # renderer (`libwallpaper-engine-renderer.so`) and `we-cef-helper`,
          # installs them under target/we-renderer-upstream/install, and then
          # the normal cargo step compiles the two Rust binaries against that
          # install via the `WE_LAYERD_PREBUILT_RENDERER_ROOT` fast path? No —
          # we deliberately use the *full* build.rs path (CMake-driven) so the
          # whole thing behaves exactly like `package/common/build-native.sh`,
          # which is what the Fedora/Ubuntu packages actually test.
          #
          # Environment consumed by build.rs's CMake invocation:
          #   CEF_ROOT             -> renderer CMake picks the binary distro CEF
          #   CMAKE_PREFIX_PATH    -> find_package/path search finds the DXC SDK
          #   PATH (DXC/bin)       -> `find_program(dxc)` for the shader builder
          #   WE_LAYERD_INSTALL_PREFIX=/usr -> build.rs accepts /usr or ~/.local
          #
          postPatch = ''
            # Splice the fetched C++ renderer into the workspace tree so build.rs
            # finds `third_party/wallpaper-engine-renderer/CMakeLists.txt`.
            # weLayerdSrc ships an empty gitlink placeholder dir here, so remove
            # it first (otherwise `cp -r` would nest the renderer one level deep).
            rm -rf third_party/wallpaper-engine-renderer
            cp -r --no-preserve=mode "${rendererSrc}" \
              third_party/wallpaper-engine-renderer
            chmod -R u+w third_party/wallpaper-engine-renderer

            # Skip `git submodule update --init --recursive` in the sandbox.
            # Upstream's own packaging ships exactly this patch (see
            # package/common/prepare-source.sh / build-without-git-metadata.patch).
            patch -p1 < "${./build-without-git-metadata.patch}"
          '';

          preConfigure = ''
            export CEF_ROOT="${cefRoot}"
            export CMAKE_PREFIX_PATH="${dxcRoot}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
            export PATH="${dxcRoot}/bin:$PATH"
            export WE_LAYERD_INSTALL_PREFIX="/usr"
            # Tell the renderer to use the prebuilt DXC rather than building the
            # (absent) vendored DirectXShaderCompiler submodule.
            export HANABI_BUILD_VENDORED_DXC=OFF
            # build.rs defaults CMAKE_BUILD_PARALLEL_LEVEL to "1"; that makes the
            # C++ renderer compile serially. Use all cores.
            export CMAKE_BUILD_PARALLEL_LEVEL="$NIX_BUILD_CORES"
          '';

          #
          # Only the two binaries. build.rs's (CMake) stage runs the first time
          # the root package compiles; building `-p we-layerd -p we-gui` is what
          # upstream's `cargo xtask install` does internally.
          #
          cargoBuildFlags = [ "-p" "we-layerd" "-p" "we-gui" ];
          doCheck = false; # unit tests need the renderer .so / a display
          # Filled in by iterating `nix build` (nixpkgs.lib.fakeHash first run).
          cargoHash = "sha256-X8bRnuP1chZoB4yhl3ecHNnS96Im2fEf1m0mP0Ys2jI=";

          # build.rs drives CMake itself (for third_party/wallpaper-engine-renderer).
          # Prevent stdenv's cmake/ninja setup hooks from auto-configuring what is
          # actually a *Rust* package whose root has no CMakeLists.txt — otherwise
          # they hijack configurePhase/buildPhase and the cargo build never runs.
          dontUseCmakeConfigure = true;

          # autoPatchelfHook registers `autoPatchelfPostFixup` in the
          # `postFixupHooks` array, which stdenv runs *after* the derivation's
          # own `postFixup` string. That means any RPATH we set in `postFixup`
          # would be (and was) clobbered by autoPatchelf. So we disable the
          # automatic invocation and instead call `autoPatchelf` ourselves at the
          # TOP of `postFixup`, then apply our GPU-safety RPATH surgery afterwards
          # — leaving nothing to overwrite it. See postFixup below.
          dontAutoPatchelf = true;

          #
          # Tools required to build, not present at runtime.
          #
          nativeBuildInputs = with pkgs; [
            cargo
            rustc
            cmake
            pkg-config
            python3           # some vendored third_party CMake invokes python
            wayland-scanner          # find_program(WAYLAND_SCANNER) in standalone_view at configure
            autoPatchelfHook
            wrapGAppsHook3
            makeWrapper
            patchelf
            desktop-file-utils
          ];

          #
          # Runtime libraries. Two categories with very different GPU rules:
          #
          #   1. nix-built renderer .so links the *host* graphics + media stack:
          #      vulkan-loader (bootstraps Mesa/NVIDIA ICDs), gstreamer, wayland,
          #      lz4, pango, fontconfig, freetype, … These MUST come from the
          #      nix store (autoPatchelf records their store RUNPATH) so the host
          #      driver is reused as-is — exactly the rule the upstream AppImage
          #      audit enforces ("don't bundle stale libdrm/libffi/libxcb copies
          #      or Mesa/NVIDIA fails with VK_ERROR_INCOMPATIBLE_DRIVER").
          #
          #   2. prebuilt CEF (libcef.so + its own SwiftShader) and DXC. CEF's
          #      own libEGL/GLES/vulkan/SwiftShader are self-contained and never
          #      touch the host GPU; they live under $out/lib/cef and resolve via
          #      `$ORIGIN`. We therefore intentionally do NOT add nix mesa/libGL
          #      to libcef's rpath — the bundled SwiftShader wins.
          #
          # autoPatchelf adds exactly the store RUNPATH needed to satisfy each
          # ELF's DT_NEEDED; it never copies/bundles host .so files, so there is
          # no "stale driver copy" hazard.
          #
          buildInputs = with pkgs; [
            # --- host GPU / graphics stack (renderer side) ---------------------
            vulkan-loader
            vulkan-headers
            mesa
            libdrm
            libglvnd
            libva                       # pkg_check_modules(libva) in render/vulkan
            wayland
            wayland-protocols
            libxkbcommon
            xdotool

            # --- C++ renderer media / text deps (pkg_check_modules) ------------
            lz4
            pango
            cairo
            fontconfig
            freetype
            harfbuzz

            # --- GStreamer (video wallpaper backend) ---------------------------
            # Added via the `gst` list below (pkgs.gst_all_1.*).
            pulseaudio             # libpulse (Rust libpulse-binding + audio)

            # --- GTK3 / GLib stack for we-gui (iced + tray-icon + rfd) ---------
            gtk3
            # we-gui's tray-icon -> libappindicator-sys dlopens
            # libayatana-appindicator3.so.1 (fallback libappindicator3.so.1) at
            # runtime. It's a dlopen, not a DT_NEEDED, so autoPatchelf can't wire
            # it into RUNPATH — we add it to the wrapper's LD_LIBRARY_PATH in
            # preFixup below. Keep it in buildInputs too so its closure (gtk,
            # ayatana-idol, libdbusmenu) is available for the wrapper path list.
            libayatana-appindicator
            glib
            glib.dev                   # glib has glib-2.0.pc; sysprof-capture-4 is a Required dep
            libsysprof-capture        # provides sysprof-capture-4.pc (glib Requires.private)
            gdk-pixbuf
            atk
            at-spi2-atk
            at-spi2-core
            pango.out             # pango lib for gtk
            cairo.out
            dbus                  # libdbus + zbus runtime (owned dbus is fine)

            # --- CEF (prebuilt) host ABI deps it dlopens / NEEDs ----------------
            # These are *not bundled*; they give libcef.so its non-GPU host deps
            # so autoPatchelf wires them into libcef.so's RUNPATH. Gstreamer+xorg
            # already covered above where possible; the cef-specific extras:
            nss
            nspr
            alsa-lib
            cups
            expat
            libxml2
            libxslt
            libxshmfence
            xorg.libX11
            xorg.libXcomposite
            xorg.libXdamage
            xorg.libXext
            xorg.libXfixes
            xorg.libXrender
            xorg.libXrandr
            xorg.libXcursor
            xorg.libXinerama
            xorg.libXScrnSaver
            xorg.libXi
            xorg.libXtst
            xorg.libxcb
            xorg.libXdmcp
            xorg.libXau

            # C++ standard library (for the prebuilt DXC + CEF libs and any
            # stdenv-built code alike).
            stdenv.cc.cc.lib
          ] ++ gst;

          #
          # GStreamer plugin discovery env augment for the daemon wrapper.
          # `gappsWrapperArgs` is consumed by wrapGAppsHook3 and applied to every
          # $out/bin/* — so we-layerd (the daemon) and we-gui both inherit it.
          #
          # We *append* to the (empty-default) array, so wrapGAppsHook still owns
          # GSettings/GTK-schema discovery and we just layer on the WE/GST env.
          #
          preFixup = ''
            gappsWrapperArgs+=(
              --set WE_LAYERD_RENDERER_LIBRARY_PATH "$out/lib/libwallpaper-engine-renderer.so"
              --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${gstPluginDirs}"
              --prefix GST_PLUGIN_PATH_1_0 : "${gstPluginDirs}"
              --prefix GST_PLUGIN_SCANNER_1_0 : "${pkgs.gst_all_1.gstreamer}/libexec/gstreamer-1.0/gst-plugin-scanner"
              # These deps are reached by `dlopen`ing a bare soname, which
              # autoPatchelf cannot see (there is no DT_NEEDED to rewrite), so
              # they have to be on LD_LIBRARY_PATH:
              #
              #   libayatana-appindicator3.so.1 -> we-gui's tray-icon
              #   libwayland-client.so.0        -> wayland-sys, used by BOTH
              #       binaries; when it is missing the daemon dies with
              #       "The wayland library could not be loaded" /
              #       "Could not find wayland compositor"
              #   libxkbcommon.so.0             -> winit's xkbcommon-dl (we-gui)
              #
              # RULE: only add libs here whose sonames CEF does NOT bundle.
              # LD_LIBRARY_PATH is searched BEFORE DT_RUNPATH, so a name that
              # also exists in $out/lib/cef (libEGL.so, libGLESv2.so,
              # libvulkan.so.1, libvk_swiftshader.so) would win over the
              # `$ORIGIN` isolation installed in postFixup, and we-cef-helper
              # inherits this environment — that silently pulls web wallpapers
              # off CEF's bundled SwiftShader and onto the host graphics stack.
              # vulkan-loader/libglvnd therefore deliberately stay out; the
              # renderer already resolves them through its own RUNPATH.
              --prefix LD_LIBRARY_PATH : "${
                pkgs.lib.makeLibraryPath [
                  pkgs.libayatana-appindicator
                  pkgs.wayland
                  pkgs.libxkbcommon
                ]
              }"
            )
          '';

          #
          # Install everything the daemon + GUI need at runtime, exactly mirroring
          # package/{fedora,ubuntu} layout:
          #
          #   $out/bin/{we-layerd,we-gui}
          #   $out/lib/libwallpaper-engine-renderer.so   (renderer runtime)
          #   $out/lib/we-cef-helper                      (CEF subprocess)
          #   $out/lib/cef/                                (CEF Release+Resources)
          #   $out/lib/we-layerd/dxc/{libdxcompiler,libdxil}.so  (DXC runtime)
          #   $out/share/applications/we-gui.desktop
          #   $out/share/icons/hicolor/scalable/apps/we-gui.svg
          #   $out/share/gnome-shell/extensions/we-layerd@aromatic/
          #
          # Runtime resolution works WITHOUT extra env for the helper & CEF:
          #   we-cef-helper  <- renderer finds <exe>/../lib/we-cef-helper
          #   CEF resources  <- <helperDir>/cef  (resolveBundledCefResourcesDir)
          #   CEF locales    <- <helperDir>/cef/locales
          # (See upstream CreateWebBackend.cpp / install_layout candidates.)
          # The renderer .so itself is found via <exe>/../lib/<name>.
          #
          # autoPatchelfHook (postFixup) then sets every ELF's RUNPATH so:
          #   renderer .so : nix vulkan/gstreamer/lz4/pango/... + $out/lib/we-layerd/dxc (DXC)
          #   we-cef-helper : $out/lib/cef (libcef.so)
          #   libcef.so     : its host deps from nix + $ORIGIN (bundled SwiftShader)
          #   libdxcompiler : libdxil (sibling) + libstdc++ (nix)
          #
          installPhase = ''
            runHook preInstall

            # cargoBuildHook in nixpkgs builds with `--target <triple>`, so the
            # binaries live under target/<triple>/release/ rather than target/release/.
            # Resolve it robustly (falls back to target/release for the no-`--target` case).
            release_dir=target/release
            for candidate in target/*-*/release; do
              if [ -e "$candidate/we-layerd" ] && [ -e "$candidate/we-gui" ]; then
                release_dir="$candidate"; break
              fi
              if [ -e "$candidate/we-layerd" ] || [ -e "$candidate/we-gui" ]; then
                release_dir="$candidate"
              fi
            done
            echo "using cargo release dir: $release_dir"
            install -Dm0755 "$release_dir/we-layerd"     $out/bin/we-layerd
            install -Dm0755 "$release_dir/we-gui"        $out/bin/we-gui

            install -Dm0755 target/we-renderer-upstream/install/lib/libwallpaper-engine-renderer.so \
              $out/lib/libwallpaper-engine-renderer.so
            install -Dm0755 target/we-renderer-upstream/install/lib/we-cef-helper \
              $out/lib/we-cef-helper

            # DXC private runtime (renderer links libdxcompiler.so)
            install -d $out/lib/we-layerd/dxc
            install -m0755 "${dxcRoot}/lib/libdxcompiler.so" $out/lib/we-layerd/dxc/libdxcompiler.so
            install -m0755 "${dxcRoot}/lib/libdxil.so"       $out/lib/we-layerd/dxc/libdxil.so

            # CEF private runtime (Release=binaries incl libcef.so, Resources=pak/locales/icudtl)
            install -d $out/lib/cef
            # --no-preserve=mode: the CEF root is a fixed-output store path (read-only);
            # `cp -a` would propagate that, making the Resources/ copy fail writing
            # into the already-created read-only dirs.
            cp -r --no-preserve=mode "${cefRoot}/Release/."  $out/lib/cef/
            cp -r --no-preserve=mode "${cefRoot}/Resources/." $out/lib/cef/
            rm -f $out/lib/cef/chrome-sandbox
            chmod -R u+w $out/lib/cef

            # Strip the large debug sections from the pinned upstream binaries
            # (matches build-native.sh / debian/rules), to shrink closures.
            strip --strip-unneeded \
              $out/lib/cef/libcef.so $out/lib/cef/libEGL.so \
              $out/lib/cef/libGLESv2.so $out/lib/cef/libvk_swiftshader.so \
              $out/lib/cef/libvulkan.so.1 \
              $out/lib/we-layerd/dxc/libdxcompiler.so \
              $out/lib/we-layerd/dxc/libdxil.so || true

            install -Dm0644 apps/we-gui/assets/we-gui.desktop \
              $out/share/applications/we-gui.desktop
            install -Dm0644 apps/we-gui/assets/we-gui-logo.svg \
              $out/share/icons/hicolor/scalable/apps/we-gui.svg

            install -d $out/share/gnome-shell/extensions/we-layerd@aromatic
            cp -r --no-preserve=mode contrib/gnome-shell-extension/we-layerd@aromatic/. \
              $out/share/gnome-shell/extensions/we-layerd@aromatic/
            find $out/share/gnome-shell/extensions/we-layerd@aromatic -type d -exec chmod 0755 {} +
            find $out/share/gnome-shell/extensions/we-layerd@aromatic -type f -exec chmod 0644 {} +

            # Sample config. NOT auto-loaded -- the daemon only ever reads
            # ~/.config/we-layerd/config.toml -- it is installed so users hitting
            # the DMA-BUF failure have a ready-made copy to start from. Note it
            # contradicts upstream's advice (docs/TROUBLESHOOTING.md tells you to
            # keep prefer_dmabuf = true); see the file's own header.
            install -Dm0644 ${./default-config.toml} \
              $out/share/we-layerd/config.default.toml

            # DXC + CEF license files
            install -Dm0644 "${dxcRoot}/LICENSE-MS.txt" \
              $out/share/doc/we-layerd/third-party/DXC-LICENSE-MS.txt || true
            install -Dm0644 "${dxcRoot}/LICENSE-LLVM.txt" \
              $out/share/doc/we-layerd/third-party/DXC-LICENSE-LLVM.txt || true
            install -Dm0644 "${cefRoot}/LICENSE.txt" \
              $out/share/doc/we-layerd/third-party/CEF-LICENSE.txt || true

            runHook postInstall
          '';

          # (Desktop file + icon are installed manually in installPhase from
          # the upstream assets, so no `desktopItems` hook is needed.)

          #
          # autoPatchelf default adds RUNPATH to satisfy DT_NEEDED from the
          # closure. But for the CEF *bundled* graphics libs we must guarantee
          # that they prefer their $ORIGIN siblings (SwiftShader EGL/GLES/Vulkan)
          # over any host copy — otherwise CEF could pick up host libvulkan/libEGL
          # and fight the host GPU. $ORIGIN in RUNPATH makes the sibling in the
          # private dir resolve first.
          #
          postFixup = ''
            # 1) Run autoPatchelf explicitly so every prebuilt ELF (the renderer
            #    .so, we-cef-helper, DXC libs, and every CEF lib) gets a correct
                       #    RUNPATH pointing into the nix store for its DT_NEEDED libs.
            #    (We set dontAutoPatchelf=true above to prevent the post-hook array
            #    entry from running *after* us and overwriting our edits below.)
            echo "postFixup: running autoPatchelf to set base RUNPATHs"
            autoPatchelf -- $out

            # 2) ---- GPU safety: renderer must use the HOST graphics stack ----
            #
            # autoPatchelf added `$out/lib/cef` to the renderer .so's RPATH because
            # it found libvulkan.so.1 there. That makes the scene/video renderer
            # load CEF's bundled SwiftShader *software* Vulkan instead of the host
            # driver — i.e. wallpapers would render in software on the wrong "GPU".
            #
            # The renderer never links CEF (it dlopens via we-cef-helper), so it has
            # no business looking in lib/cef. Strip that directory from its RPATH;
            # libvulkan/libGLES/libOpenGL/libdrm then resolve to the nix store
            # (vulkan-loader/libglvnd/libdrm) = the real host ICDs.
            renderer=$out/lib/libwallpaper-engine-renderer.so
            rp=$(patchelf --print-rpath "$renderer")
            rp_filtered=$(printf '%s\n' "$rp" | tr ':' '\n' | grep -v -e '/lib/cef$' | paste -sd:)
            # Append vulkan-loader/lib if not already present: autoPatchelf had
            # satisfied the renderer's `libvulkan.so.1` DT_NEEDED from the bundled
            # CEF copy in $out/lib/cef (which we just stripped). The real host
            # provider is the nix vulkan-loader dispatcher, which bootstraps the
            # Mesa/NVIDIA ICDs at runtime. libglvnd (GLES/EGL/GL) is already in the
            # RUNPATH from autoPatchelf (it served libGLESv2/libOpenGL/libEGL).
            vulkan_loader_lib="${pkgs.vulkan-loader}/lib"
            case ":$rp_filtered:" in
              *":$vulkan_loader_lib:"*) ;;
              *) rp_filtered="$rp_filtered:$vulkan_loader_lib" ;;
            esac
            patchelf --set-rpath "$rp_filtered" "$renderer"
            echo "postFixup: renderer RUNPATH = $(patchelf --print-rpath "$renderer")"

            # ---- CEF isolation: SwiftShader siblings win over host copies ----
            #
            # libcef.so / libEGL.so / libGLESv2.so / libvk_swiftshader.so /
            # libvulkan.so.1 are CEF's OWN software-rendered GL/EGL/Vulkan stack
            # used for web wallpapers'offscreen render. They must resolve to their
            # bundled siblings in $out/lib/cef (via $ORIGIN) BEFORE any host copy
            # the daemon may have on its LD_LIBRARY_PATH — otherwise a host
            # libEGL/libvulkan could clash and CEF fails to initialise.
            # Prepend $ORIGIN so the private dir always wins. NOTE: also strip any
            # host vulkan-loader/glvnd store dirs we appended in step 1 from these
            # specific 5 files, so a stray host libvulkan never shadows SwiftShader.
            for f in libcef.so libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1; do
              p="$out/lib/cef/$f"
              [ -f "$p" ] || continue
              existing=$(patchelf --print-rpath "$p" 2>/dev/null || true)
              # Drop any store dir that provides competing host graphics libs.
              filtered=$(printf '%s\n' "$existing" | tr ':' '\n' \
                | grep -v -E '/(libglvnd|vulkan-loader|mesa|libdrm)-[0-9]' \
                | paste -sd:)
              case ":$filtered:" in
                *':$ORIGIN:'*)
                  newrp="$filtered"
                  ;;
                *)
                  if [ -z "$filtered" ]; then
                    newrp='$ORIGIN'
                  else
                    newrp='$ORIGIN:'"$filtered"
                  fi
                  ;;
              esac
              patchelf --set-rpath "$newrp" "$p"
              echo "postFixup: $f RUNPATH = $newrp"
            done
          '';

          # The project is x86_64-only: we-cef-helper uses an x86_64 assembly
          # trampoline (internal/cef/helper/dso_start_x86_64.S) and CEF minimal
          # has no aarch64 build. Express that on the flake level (see below).
          meta = with lib; {
            description = "Native Wallpaper Engine runtime for Wayland (daemon + GUI)";
            homepage = "https://github.com/Aromatic05/we-layerd";
            license = licenses.unfree; # project source has no published license
            platforms = [ "x86_64-linux" ];
            mainProgram = "we-gui";
          };
        };
    in
    {
      # we-cef-helper has an x86_64-only assembly trampoline and CEF minimal is
      # x86_64-only, so we only expose an x86_64-linux package. Trying to build
      # on any other platform would fail mid-CMake.
      # Build with an allowUnfree-enabled nixpkgs instance so the resulting
      # derivation is pure and consumers don't need `--impure` nor
      # `NIXPKGS_ALLOW_UNFREE=1`. (we-layerd's own source carries no published
      # license, so it's marked unfree.) The fetchers above still use plain
      # `nixpkgs.legacyPackages` — fetchFromGitHub/fetchurl are fixed-output
      # derivations independent of config, so they're shared & cached normally.
      packages.x86_64-linux.we-layerd = buildPkg {
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config = { allowUnfree = true; };
        };
      };
      packages.x86_64-linux.default = self.packages.x86_64-linux.we-layerd;
    };
}

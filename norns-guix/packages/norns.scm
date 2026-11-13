(define-module (norns-guix packages norns)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix git-download)
  #:use-module (guix download)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system waf)
  #:use-module (guix utils)
  #:use-module (gnu packages)
  #:use-module (gnu packages audio)         ; jack-2, liblo
  #:use-module (gnu packages avahi)
  #:use-module (gnu packages gtk)           ; cairo
  #:use-module (gnu packages linux)         ; alsa-lib, eudev
  #:use-module (gnu packages lua)
  #:use-module (gnu packages ncurses)
  #:use-module (gnu packages networking)    ; nanomsg
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages pulseaudio)    ; libsndfile
  #:use-module (gnu packages readline)
  #:use-module (gnu packages sdl)
  #:use-module (gnu packages xorg)          ; libevdev
  #:use-module (gnu packages assembly))   ; simde

;;;
;;; libgpiod 1.x -- norns uses the v1 API; Guix only has v2.
;;;
(define-public libgpiod-1
  (package
    (name "libgpiod")
    (version "1.6.5")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://mirrors.edge.kernel.org/pub/software/libs/libgpiod/"
             "libgpiod-" version ".tar.xz"))
       (sha256
        (base32 "1g3jmafn295s7zxj8qdbnw92f38xr3jp568cg3xs2dghgdlhya5f"))))
    (build-system gnu-build-system)
    (home-page "https://git.kernel.org/pub/scm/libs/libgpiod/libgpiod.git/")
    (synopsis "Library for the Linux GPIO character device (v1 API)")
    (description
     "libgpiod is a C library for interacting with the Linux GPIO character
device.  This is the 1.x series, whose API older programs such as norns
are written against.")
    (license license:lgpl2.1+)))

;;;
;;; libmonome -- library for monome grid/arc devices
;;;
(define-public libmonome
  (package
    (name "libmonome")
    (version "1.4.11")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/monome/libmonome/archive/refs/tags/v"
             version ".tar.gz"))
       (file-name (string-append name "-" version ".tar.gz"))
       (sha256
        (base32 "1ml1y6n1c2f20i3ijky5j5gb80w6k898p03qwlcagljrw5gkxzwf"))))
    (build-system waf-build-system)
    (arguments
     (list
      #:tests? #f
      ;; norns talks to devices directly; the OSC protocol isn't needed.
      #:configure-flags #~'("--disable-osc")
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'configure 'set-ldflags
            (lambda _
              (setenv "LDFLAGS"
                      (string-append "-Wl,-rpath=" #$output "/lib")))))))
    (native-inputs (list pkg-config))
    (inputs (list eudev ncurses))          ; ncurses: the examples
    (home-page "https://github.com/monome/libmonome")
    (synopsis "Library for interaction with monome devices")
    (description
     "libmonome is a library for easy interaction with monome devices,
providing a simple API for communicating with the monome grid and arc
hardware over serial.")
    (license license:isc)))

;;; norns bundles waf 2.0.14, which imports Python's `imp' module (removed in
;;; Python 3.12).
(define waf-2.1
  (origin
    (method url-fetch)
    (uri "https://waf.io/waf-2.1.9")
    (sha256
     (base32 "0r389ax8i174xbhvdlgggnhr4sj1k2176nim9s1kkw1ldnnfwdg2"))))

;;;
;;; norns -- sound computer platform
;;;
;;; This is the v2.9.4 line, which the norns hardware runs.  The v3 rewrite
;;; on main doesn't build with --desktop yet.
(define-public norns
  (let ((commit "f9fa0c5ce5883ec7f185765ffdf8b3750061289e")
        (revision "2"))
    (package
      (name "norns")
      (version (git-version "2.9.4" revision commit))
      (source
       (origin
         (method git-fetch)
         (uri (git-reference
               (url "https://github.com/monome/norns")
               (commit commit)
               (recursive? #t)))
         (file-name (git-file-name name version))
         (sha256
          (base32 "0rbw5m5j3pbvjg4v037ji8d86i75gn6zlpkf9syi5jf9fvc18m5d"))
         ;; Pump SDL events from matron's event loop (the window otherwise
         ;; never processes any) and map keys in the window to K1-3/E1-3.
         (patches
          (list (local-file "patches/norns-desktop-sdl-input.patch")))))
      (build-system waf-build-system)
      (arguments
       (list
        #:tests? #f
        #:configure-flags #~'("--desktop")
        #:phases
        #~(modify-phases %standard-phases
            (add-after 'unpack 'use-newer-waf
              (lambda _
                (copy-file #$waf-2.1 "waf")
                (chmod "waf" #o755)))
            (add-after 'unpack 'fix-desktop-build
              (lambda* (#:key inputs #:allow-other-keys)
                ;; The version hash comes from git, which isn't here.
                (substitute* "wscript"
                  (("return subprocess\\.check_output\\(\\[")
                   (string-append "return '" #$(string-take commit 7)
                                  "'\n        subprocess.check_output([")))
                ;; -mfpu=neon is for the Pi; x86 compilers reject it.
                (substitute* "matron/wscript"
                  (("'-mfpu=neon'") ""))
                ;; The OLED driver is always compiled and uses NEON
                ;; intrinsics; SIMDe provides them portably.
                (mkdir-p "shim")
                (call-with-output-file "shim/arm_neon.h"
                  (lambda (port)
                    (display "#define SIMDE_ENABLE_NATIVE_ALIASES
#include <simde/arm/neon.h>
" port)))
                (setenv "C_INCLUDE_PATH"
                        (string-append (getcwd) "/shim:"
                                       (or (getenv "C_INCLUDE_PATH") "")))
                ;; glib is only used for a typedef and a byte-order macro.
                (substitute* "matron/src/device/device_hid.c"
                  (("#include <glib.h>")
                   "#include <endian.h>
#include <stdint.h>
typedef uint16_t guint16;
#define GINT16_TO_LE(x) htole16(x)"))
                ;; Metro threads get a PTHREAD_STACK_MIN (16 KiB) stack, which
                ;; glibc refuses (EINVAL) once static TLS outgrows it, as it
                ;; does with these libraries: those metros never run.
                (substitute* "matron/src/metro.c"
                  (("pthread_attr_setstacksize\\(&attr, PTHREAD_STACK_MIN\\)")
                   "pthread_attr_setstacksize(&attr, 256 * 1024)"))
                ;; relied on <string> arriving transitively
                (substitute* "crone/src/BufDiskWorker.h"
                  (("#include <atomic>")
                   "#include <atomic>\n#include <string>"))
                ;; norns asks pkg-config for 'lua53'; Guix names it lua-5.3.
                (mkdir-p "pkgconfig")
                (copy-file (search-input-file inputs
                                              "lib/pkgconfig/lua-5.3.pc")
                           "pkgconfig/lua53.pc")
                (setenv "PKG_CONFIG_PATH"
                        (string-append (getcwd) "/pkgconfig:"
                                       (getenv "PKG_CONFIG_PATH")))))
            (add-after 'unpack 'remove-hardcoded-home
              (lambda _
                (substitute* "lua/core/menu/select.lua"
                  (("'/home/we/dust/code/'") "_path.code"))))
            (add-after 'install 'install-runtime-tree
              ;; matron finds everything under $HOME/norns: Lua, fonts,
              ;; SuperCollider classes, docs and matronrc.lua.  The service
              ;; points that at share/norns.
              (lambda _
                (let ((share (string-append #$output "/share/norns")))
                  (for-each (lambda (dir)
                              (copy-recursively dir
                                                (string-append share "/" dir)))
                            '("lua" "sc" "resources" "doc"))
                  (install-file "matronrc.lua" share)))))))
      (native-inputs (list pkg-config simde))
      (inputs (list alsa-lib
                    avahi
                    cairo
                    eudev
                    jack-2
                    libevdev
                    libgpiod-1
                    liblo
                    libmonome
                    libsndfile
                    lua-5.3
                    nanomsg
                    ncurses
                    readline
                    sdl2))
      (home-page "https://github.com/monome/norns")
      (synopsis "Sound computer platform for musical exploration")
      (description
       "norns is an open-source sound computer platform.  It runs Lua scripts
on top of a SuperCollider audio engine.  This package builds the desktop
variant: matron (script engine and screen, shown in an SDL window), crone
(the mixer and softcut engine), ws-wrapper (the websocket bridge maiden
uses), maiden-repl and watcher.")
      (license license:gpl3+))))

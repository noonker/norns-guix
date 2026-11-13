(define-module (norns-guix packages norns)
  #:use-module (guix)
  #:use-module (guix packages)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix git-download)
  #:use-module (guix download)
  #:use-module (guix build-system waf)
  #:use-module (guix utils)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages audio)         ; jack-2, libsndfile, liblo
  #:use-module (gnu packages linux)         ; eudev, alsa-lib, libevdev
  #:use-module (gnu packages gtk)           ; cairo
  #:use-module (gnu packages fontutils)     ; freetype
  #:use-module (gnu packages sdl)           ; sdl2
  #:use-module (gnu packages lua)           ; lua
  #:use-module (gnu packages networking)    ; nanomsg
  #:use-module (gnu packages avahi)         ; avahi
  #:use-module (gnu packages ncurses)       ; ncurses
  #:use-module (gnu packages readline))     ; readline

;;;
;;; Lua 5.3 reference (norns requires this specific version)
;;;
(define lua-5.3
  (specification->package "lua@5.3"))

;;;
;;; libmonome - library for monome grid/arc devices
;;;
(define-public libmonome
  (package
    (name "libmonome")
    (version "1.4.9")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/monome/libmonome/archive/refs/tags/v"
             version ".tar.gz"))
       (sha256
        (base32 "1f08iryjl4rczxxwpni84hj0qwv11zi9b1ia7lkraj4ciwqm2nql"))))
    (build-system waf-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'configure 'set-ldflags
            (lambda _
              (setenv "LDFLAGS"
                      (string-append "-Wl,-rpath=" #$output "/lib")))))))
    (native-inputs (list pkg-config))
    (inputs (list eudev liblo))
    (home-page "https://github.com/monome/libmonome")
    (synopsis "Library for interaction with monome devices")
    (description
     "libmonome is a library for easy interaction with monome devices,
providing a simple API for communicating with the monome grid and arc
hardware over serial and OSC protocols.")
    (license license:isc)))

;;;
;;; norns - sound computer platform
;;;
(define-public norns
  (package
    (name "norns")
    (version "2.9.4")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/monome/norns")
             (commit (string-append "v" version))
             (recursive? #t)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0000000000000000000000000000000000000000000000000000"))
       (modules '((guix build utils)))
       (snippet
        '(begin
           ;; Remove libgpiod check -- Guix has v2, norns needs v1; not
           ;; needed for desktop builds anyway.
           (substitute* "wscript"
             (("conf\\.check_cfg\\(package='libgpiod'[^)]*\\)") ""))
           ;; Fix Lua pkg-config name: norns expects 'lua53', Guix
           ;; provides 'lua-5.3'.
           (substitute* "wscript"
             (("'lua53'") "'lua-5.3'"))
           ;; Remove ARM-only -mfpu=neon CFLAG from matron build.
           (substitute* "matron/wscript"
             (("'-mfpu=neon',?\\s*") ""))
           ;; Fix WAF USE variable names: pkg-config name 'lua-5.3'
           ;; becomes USE flag 'LUA_5_3' (was 'LUA53' for 'lua53').
           (substitute* (find-files "." "wscript$")
             (("LUA53") "LUA_5_3"))))))
    (build-system waf-build-system)
    (arguments
     (list
      #:tests? #f
      #:configure-flags #~'("--desktop")
      #:phases
      #~(modify-phases %standard-phases
          (replace 'build
            (lambda* (#:key parallel-build? #:allow-other-keys)
              (let ((jobs (if parallel-build?
                              (number->string (parallel-job-count))
                              "1")))
                (invoke "./waf" "build" "--desktop"
                        (string-append "-j" jobs)))))
          (replace 'install
            (lambda* (#:key outputs #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (bin (string-append out "/bin"))
                     (share (string-append out "/share/norns")))
                ;; Install the five built binaries.
                (mkdir-p bin)
                (for-each
                 (lambda (name)
                   (install-file (string-append "build/" name "/" name)
                                 bin))
                 '("matron" "crone" "ws-wrapper" "maiden-repl" "watcher"))
                ;; Install Lua core libraries.
                (copy-recursively "lua" (string-append share "/lua"))
                ;; Install SuperCollider engine classes.
                (copy-recursively "sc" (string-append share "/sc"))
                ;; Install documentation if present.
                (when (file-exists? "doc")
                  (copy-recursively "doc"
                                    (string-append share "/doc")))))))))
    (native-inputs (list pkg-config))
    (inputs (list alsa-lib
                  jack-2
                  libsndfile
                  liblo
                  avahi
                  nanomsg
                  cairo
                  freetype
                  sdl2
                  eudev
                  libevdev
                  lua-5.3
                  libmonome
                  ncurses
                  readline))
    (home-page "https://github.com/monome/norns")
    (synopsis "Sound computer platform for musical exploration")
    (description
     "norns is an open-source sound computer platform.  It runs Lua scripts
on top of a SuperCollider audio engine, providing a creative environment for
musical exploration.  This package builds the core norns components for
desktop use: matron (the main UI/script engine), crone (the audio engine),
ws-wrapper (WebSocket bridge), maiden-repl (REPL interface), and watcher
(device hotplug monitor).")
    (license license:gpl3+)))

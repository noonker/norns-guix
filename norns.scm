(define-module (guix-packager)
  #:use-module (guix)
  #:use-module (srfi srfi-1)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages)
  #:use-module (guix build-system waf)
  #:use-module (guix channels)
  #:use-module (guix inferior)
  ;; New modules needed for dependencies
  #:use-module (gnu packages pkg-config) ; For pkg-config
  #:use-module (gnu packages python) ; For pkg-config
  #:use-module (gnu packages audio)      ; For liblo
  #:use-module (gnu packages xorg)      ; For liblo
  #:use-module (gnu packages gtk)      ; For liblo
  #:use-module (gnu packages lua)      ; For liblo
  #:use-module (gnu packages version-control)      ; For liblo
  #:use-module (gnu packages networking)      ; For liblo
  #:use-module (gnu packages pulseaudio)      ; For liblo
  #:use-module (gnu packages sdl)      ; For liblo
  #:use-module (gnu packages avahi)      ; For liblo
  #:use-module (gnu packages ncurses)      ; For ncurses
  #:use-module (gnu packages linux))     ; For eudev (libudev)


(define guix-python-39-channel
  (list (channel
         (name 'guix)
         (url "https://git.savannah.gnu.org/git/guix.git")
         (commit "472706ae2f9160833951a4e4bcc4c206e03097b0")
	 (introduction
          (make-channel-introduction
           "9edb3f66fd807b096b48283debdcddccfea34bad" ;; The historic commit where auth was introduced
           (openpgp-fingerprint
            "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))
	 )))

;; Initialize the inferior (the time machine)
(define inferior-python-39-guix
  (inferior-for-channels guix-python-39-channel))

;; Lookup the package inside that inferior instance
(define python-3.9-inferior
  (first (lookup-inferior-packages inferior-python-39-guix "python-wrapper" "3.9.9")))

(define lua-5.3
  (specification->package "lua@5.3.5"))

(define-public libmonome
  (package
    (name "libmonome")
    (version "1.4.9")
    (source
      (origin
        (method url-fetch)
        (uri "https://github.com/monome/libmonome/archive/refs/tags/v1.4.9.tar.gz")
        (sha256 (base32 "1f08iryjl4rczxxwpni84hj0qwv11zi9b1ia7lkraj4ciwqm2nql"))))
    (build-system waf-build-system)

    (arguments
     (list 
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          ;; We add a phase before configure to set the linker flags.
          (add-before 'configure 'set-ldflags
            (lambda _
              ;; #$output is a special G-expression variable that resolves 
              ;; to the final /gnu/store/... directory of this package.
              (setenv "LDFLAGS" 
                      (string-append "-Wl,-rpath=" #$output "/lib")))))))
    
    ;; TOOLS: Things needed to run the build process
    (native-inputs (list pkg-config))

    ;; LIBRARIES: Things libmonome links against
    ;; libmonome requires libudev (eudev in Guix) for Linux hardware support
    ;; and usually liblo for OSC support.
    (inputs (list eudev liblo ncurses))

    (home-page "https://github.com/monome/libmonome")
    (synopsis "Library for easy interaction with monome devices")
    (description "libmonome is a library for easy interaction with monome devices.")
    (license license:isc)))

(define-public norns
  (package
    (name "norns")
    (version "260102")
    (source
      (origin
        (method url-fetch)
        (uri "https://github.com/monome/norns/releases/download/v2.9.4/norns260102.tgz")
        (sha256 (base32 "0lxgq2ska9lapswvfh2f4n9jfp78lmcllmbada7dqjf43r24hvw1")))
      )
    (build-system waf-build-system)
    (arguments
     (list
      #:configure-flags #~'("--desktop")
      #:python python-3.9-inferior
      #:phases
      #~(modify-phases %standard-phases
	  (replace 'build
            (lambda* (#:key parallel-build? #:allow-other-keys)
              (let ((jobs (if parallel-build?
                              (number->string (parallel-job-count))
                              "1")))
		(invoke "./waf" "build"
			"--desktop"
			(string-append "-j" jobs)))))
          (add-after 'unpack 'enter-source-directory
            (lambda _
              ;; Guix automatically enters "260102" because it's the only
              ;; top-level directory. Now we manually enter the inner "norns".
              (chdir "norns")
              #t))
	  (add-after 'enter-source-directory 'patch-wscript
            (lambda _
              ;; The wscript looks for 'lua53', but Guix provides 'lua.pc'
              (substitute* "wscript"
                (("lua53") "lua-5.3"))
              #t))
	  )))
    (native-inputs (list pkg-config python-3.9-inferior git alsa-lib libevdev libgpiod cairo libsoundio lua-5.3 nanomsg avahi libsndfile jack-2 libmonome sdl2))

    (inputs (list eudev liblo ncurses lua-5.3))

    (home-page "https://github.com/monome/libmonome")
    (synopsis "Library for easy interaction with monome devices")
    (description "libmonome is a library for easy interaction with monome devices.")
    (license license:isc)))

libmonome
norns

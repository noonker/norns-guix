(define-module (norns-guix packages norns-extras)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix git-download)
  #:use-module (guix download)
  #:use-module (guix build-system cmake)
  #:use-module (guix build-system go)
  #:use-module (gnu packages algebra)       ; fftwf
  #:use-module (gnu packages audio)         ; supercollider
  #:use-module (gnu packages golang-vcs)    ; go-git
  #:use-module (gnu packages golang-web)    ; gin
  #:use-module (gnu packages golang-xyz)    ; cobra, viper, logrus, go-systemd
  #:use-module (gnu packages pkg-config))

;;;
;;; sc3-plugins -- community UGen plugins for SuperCollider
;;;
;;; Built against Guix's own SuperCollider source so the plugin API matches
;;; the scsynth it runs in.  Installs to
;;; share/SuperCollider/Extensions/SC3plugins (classes and plugins together).
(define-public sc3-plugins
  (package
    (name "sc3-plugins")
    (version (package-version supercollider))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/supercollider/sc3-plugins")
             (commit (string-append "Version-" version))
             (recursive? #t)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0rqppagzl1yssjkxkj4rgd0cnj9866yxplqc11icxppdn0cqxs39"))))
    (build-system cmake-build-system)
    (arguments
     (list
      #:tests? #f
      #:configure-flags
      #~(list (string-append "-DSC_PATH=" #$(package-source supercollider))
              "-DNATIVE=OFF"
              "-DSUPERNOVA=OFF"
              "-DCMAKE_BUILD_TYPE=Release")))
    (native-inputs (list pkg-config))
    (inputs (list fftwf))                 ; single-precision FFTW
    (home-page "https://github.com/supercollider/sc3-plugins")
    (synopsis "Community collection of SuperCollider UGen plugins")
    (description
     "sc3-plugins is a community-maintained collection of unit generator
(UGen) plugins for SuperCollider, extending its built-in synthesis,
analysis and processing UGens.  Many norns scripts' engines use them.")
    (license license:gpl2+)))
;;;
;;; maiden -- web editor for norns
;;;
;;; The Go server is built from source.  The web app is a React app whose
;;; build needs Node 16 and an npm tree Guix doesn't have, so it comes
;;; prebuilt from norns' official v2.9.4 release, which ships this same
;;; maiden v1.1.6 (as the norns hardware runs it).
;;;
(define norns-2.9.4-release
  (origin
    (method url-fetch)
    (uri "https://github.com/monome/norns/releases/download/v2.9.4/norns260102.tgz")
    (sha256
     (base32 "0lxgq2ska9lapswvfh2f4n9jfp78lmcllmbada7dqjf43r24hvw1"))))

(define-public maiden
  (package
    (name "maiden")
    (version "1.1.6")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/monome/maiden")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0b35d3m8600l341k8jpdq7ycyk9kk6lkj3xz5ywb0ndk9yyblxx0"))))
    (build-system go-build-system)
    (arguments
     (list
      #:import-path "github.com/monome/maiden"
      #:install-source? #f
      #:tests? #f
      #:build-flags
      #~(list (string-append "-ldflags=-X github.com/monome/maiden/cmd.version=v"
                             #$version))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'use-go-systemd-v22
            ;; Guix packages go-systemd under its v22 import path; the dbus
            ;; API maiden uses is the same.
            (lambda* (#:key import-path #:allow-other-keys)
              (substitute* (string-append "src/" import-path "/cmd/server.go")
                (("\"github.com/coreos/go-systemd/dbus\"")
                 "\"github.com/coreos/go-systemd/v22/dbus\""))))
          (add-after 'install 'install-app
            ;; share/maiden: the web app, the catalog sources and the config,
            ;; laid out as in a norns' ~/maiden.
            (lambda* (#:key import-path #:allow-other-keys)
              (let ((share (string-append #$output "/share/maiden"))
                    (src (string-append "src/" import-path)))
                (mkdir-p share)
                (invoke "tar" "xzf" #$norns-2.9.4-release "-C" share
                        "--strip-components=2" "260102/maiden/app")
                (for-each (lambda (file)
                            (install-file file (string-append share
                                                              "/dist/sources")))
                          (find-files (string-append src "/sources")
                                      "\\.json$"))
                (install-file (string-append src "/maiden.yaml") share)))))))
    (native-inputs
     (list go-github-com-coreos-go-systemd-v22
           go-github-com-gin-gonic-gin
           go-github-com-go-git-go-git-v5
           go-github-com-sirupsen-logrus
           go-github-com-spf13-cobra
           go-github-com-spf13-viper))
    (home-page "https://github.com/monome/maiden")
    (synopsis "Web editor for norns")
    (description
     "maiden is the web-based editor for the norns sound computer: a code
editor for the scripts in dust, REPLs for matron and SuperCollider, and a
catalog for installing community scripts.")
    (license license:gpl3+)))

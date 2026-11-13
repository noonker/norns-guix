(define-module (norns-guix packages norns-extras)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix git-download)
  #:use-module (guix build-system cmake)
  #:use-module (gnu packages algebra)       ; fftwf
  #:use-module (gnu packages audio)         ; supercollider
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

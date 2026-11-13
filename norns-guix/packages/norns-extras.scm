(define-module (norns-guix packages norns-extras)
  #:use-module (guix)
  #:use-module (guix packages)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix git-download)
  #:use-module (guix download)
  #:use-module (guix build-system cmake)
  #:use-module (guix build-system gnu)
  #:use-module (guix utils)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages audio)
  #:use-module (gnu packages algebra)
  #:use-module (gnu packages golang)
  #:use-module (gnu packages node))

;;;
;;; SuperCollider source -- needed at build time for sc3-plugins (SC_PATH).
;;; This is NOT a package, just an origin providing the header tree.
;;;
(define supercollider-source
  (origin
    (method git-fetch)
    (uri (git-reference
          (url "https://github.com/supercollider/supercollider")
          (commit "Version-3.14.0")
          (recursive? #t)))
    (file-name "supercollider-source-3.14.0-checkout")
    (sha256
     ;; TODO: compute with  guix hash -xr <checkout>
     (base32 "0000000000000000000000000000000000000000000000000000"))))

;;;
;;; sc3-plugins - community UGen plugins for SuperCollider
;;;
(define-public sc3-plugins
  (package
    (name "sc3-plugins")
    (version "3.13.0")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/supercollider/sc3-plugins")
             (commit (string-append "Version-" version))
             (recursive? #t)))
       (file-name (git-file-name name version))
       (sha256
        ;; TODO: compute with  guix hash -xr <checkout>
        (base32 "0000000000000000000000000000000000000000000000000000"))))
    (build-system cmake-build-system)
    (arguments
     (list
      #:tests? #f
      #:configure-flags
      #~(list
         (string-append "-DSC_PATH=" #$supercollider-source)
         "-DNATIVE=OFF"
         "-DSUPERNOVA=OFF"
         "-DIN_PLACE_BUILD=OFF"
         "-DCMAKE_BUILD_TYPE=Release")))
    (native-inputs (list pkg-config))
    (inputs (list supercollider fftw))
    (home-page "https://github.com/supercollider/sc3-plugins")
    (synopsis "Community collection of SuperCollider UGen plugins")
    (description
     "sc3-plugins is a community-maintained collection of unit generator
(UGen) plugins for SuperCollider.  It includes synthesis, analysis, and
processing plugins such as the VOSIM, Membrane, and various filter UGens
that extend SuperCollider's built-in capabilities.")
    (license license:gpl2+)))

;;;
;;; maiden - web-based development environment for norns
;;;
;;; NOTE: Building maiden in Guix requires vendored Go modules and an
;;; offline Node.js/yarn cache, since the build sandbox has no network
;;; access.  The user must prepare these before building:
;;;
;;;   1. Clone maiden and run:  cd maiden && go mod vendor
;;;      Then create a tarball of the vendor/ directory.
;;;   2. Run:  cd web && yarn install
;;;      Then create a tarball of the node_modules/ directory.
;;;
;;; These tarballs are referenced as additional origins below.
;;; Until they are prepared, this package definition serves as a
;;; documented template.
;;;
(define-public maiden
  (package
    (name "maiden")
    (version "1.1.6")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/monome/maiden")
             (commit (string-append "v" version))
             (recursive? #t)))
       (file-name (git-file-name name version))
       (sha256
        ;; TODO: compute with  guix hash -xr <checkout>
        (base32 "0000000000000000000000000000000000000000000000000000"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)

          ;; Unpack vendored Go modules and Node.js dependencies.
          ;; These must be prepared offline -- see package comment above.
          (add-after 'unpack 'unpack-vendor-deps
            (lambda* (#:key native-inputs inputs #:allow-other-keys)
              ;; Go vendor directory.
              (when (assoc-ref (or native-inputs inputs)
                               "maiden-go-vendor")
                (invoke "tar" "xf"
                        (assoc-ref (or native-inputs inputs)
                                   "maiden-go-vendor")
                        "--strip-components=1"))
              ;; Node.js modules for the web frontend.
              (when (assoc-ref (or native-inputs inputs)
                               "maiden-node-modules")
                (with-directory-excursion "web"
                  (invoke "tar" "xf"
                          (assoc-ref (or native-inputs inputs)
                                     "maiden-node-modules")
                          "--strip-components=1")))))

          ;; Build the React frontend.
          (add-before 'build 'build-frontend
            (lambda _
              (with-directory-excursion "web"
                (setenv "HOME" (getcwd))
                (setenv "NODE_OPTIONS" "--openssl-legacy-provider")
                (invoke "yarn" "build"))))

          ;; Build the Go backend.
          (replace 'build
            (lambda _
              (setenv "GOPATH" (string-append (getcwd) "/go"))
              (setenv "GOCACHE"
                      (string-append (getcwd) "/.cache/go-build"))
              (setenv "GOFLAGS" "-mod=vendor")
              (invoke "go" "build"
                      "-ldflags"
                      (string-append
                       "-X main.version=" #$version
                       " -X main.compileTime=guix-build")
                      "-o" "maiden")))

          ;; Install binary and web assets.
          (replace 'install
            (lambda* (#:key outputs #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (bin (string-append out "/bin"))
                     (share (string-append out "/share/maiden")))
                (install-file "maiden" bin)
                (copy-recursively "web/build"
                                  (string-append share "/app/build"))))))))
    (native-inputs
     (list go node
           ;; TODO: Add vendored dependency tarballs:
           ;; ("maiden-go-vendor"
           ;;  ,(origin
           ;;     (method url-fetch)
           ;;     (uri "file:///path/to/maiden-go-vendor-1.1.6.tar.gz")
           ;;     (sha256 (base32 "..."))))
           ;; ("maiden-node-modules"
           ;;  ,(origin
           ;;     (method url-fetch)
           ;;     (uri "file:///path/to/maiden-node-modules-1.1.6.tar.gz")
           ;;     (sha256 (base32 "..."))))
           ))
    (home-page "https://github.com/monome/maiden")
    (synopsis "Web-based development environment for norns")
    (description
     "maiden is the web-based development environment for the norns sound
computer.  It provides a browser-based code editor for writing and managing
Lua scripts, a REPL for interacting with matron and SuperCollider, and a
project manager for installing community scripts from the norns catalog.")
    (license license:gpl3+)))

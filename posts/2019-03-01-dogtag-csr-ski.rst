---
tags: dogtag, howto
---

Specifying a CA Subject Key Identifier during Dogtag installation
=================================================================

When installing Dogtag with an externally-signed CA certificate, it
is sometimes necessary to include a specific *Subject Key
Identifier* value in the CSR.  In this post I will demonstrate how
to do this.

What is a Subject Key Identifier?
---------------------------------

The X.509 *Subject Key Identifier (SKI)* extension declares a unique
identifier for the public key in the certificate.  It is required on
all CA certificates.  CAs propagate their own SKI to the *Issuer Key
Identifier (AKI)* extension on issued certificates.  Together, these
facilitate efficient certification path construction; certificate
databases can index certificates by SKI.

The SKI must be unique for a given key.  Most often it is derived
from the public key data using a cryptographic digest, usually
SHA-1.  But any method of generating a unique value is acceptable.

For example, let's look at the CA certificate and one of the service
certificates in a FreeIPA deployment.  The CA is self-signed and
therefore contains the same value in both the SKI and AKI
extensions::

  % openssl x509 -text < /etc/ipa/ca.crt
  Certificate:
      Data:
          Version: 3 (0x2)
          Serial Number: 1 (0x1)
          Signature Algorithm: sha256WithRSAEncryption
          Issuer: O = IPA.LOCAL 201902271325, CN = Certificate Authority
          Validity
              Not Before: Feb 27 03:30:22 2019 GMT
              Not After : Feb 27 03:30:22 2034 GMT
          Subject: O = IPA.LOCAL 201902271325, CN = Certificate Authority
          Subject Public Key Info:
              < elided >
          X509v3 extensions:
              X509v3 Authority Key Identifier:
                  keyid:C9:29:69:D0:14:A4:AB:11:D4:11:B1:35:31:81:08:B6:A9:30:D3:0A

              X509v3 Basic Constraints: critical
                  CA:TRUE
              X509v3 Key Usage: critical
                  Digital Signature, Non Repudiation, Certificate Sign, CRL Sign
              X509v3 Subject Key Identifier:
                  C9:29:69:D0:14:A4:AB:11:D4:11:B1:35:31:81:08:B6:A9:30:D3:0A
              Authority Information Access:
                  OCSP - URI:http://ipa-ca.ipa.local/ca/ocsp
    ...


Whereas the end entity certificate has the CA's SKI in its AKI, and
its SKI is different::

    % sudo cat /var/lib/ipa/certs/httpd.crt | openssl x509 -text
    Certificate:
        Data:
          Version: 3 (0x2)                                                                                                                                                                                  [43/9508]
          Serial Number: 9 (0x9)
          Signature Algorithm: sha256WithRSAEncryption
          Issuer: O = IPA.LOCAL 201902271325, CN = Certificate Authority
          Validity
              Not Before: Feb 27 03:32:57 2019 GMT
              Not After : Feb 27 03:32:57 2021 GMT
          Subject: O = IPA.LOCAL 201902271325, CN = f29-0.ipa.local
          Subject Public Key Info:
              < elided >
          X509v3 extensions:
              X509v3 Authority Key Identifier:
                  keyid:C9:29:69:D0:14:A4:AB:11:D4:11:B1:35:31:81:08:B6:A9:30:D3:0A

              Authority Information Access:
                  OCSP - URI:http://ipa-ca.ipa.local/ca/ocsp

              X509v3 Key Usage: critical
                  Digital Signature, Non Repudiation, Key Encipherment, Data Encipherment
              X509v3 Extended Key Usage:
                  TLS Web Server Authentication, TLS Web Client Authentication
              X509v3 CRL Distribution Points:

                  Full Name:
                    URI:http://ipa-ca.ipa.local/ipa/crl/MasterCRL.bin
                  CRL Issuer:
                    DirName:O = ipaca, CN = Certificate Authority

              X509v3 Subject Key Identifier:
                  FE:D2:8A:72:C8:D5:78:79:C9:04:04:A8:39:37:7F:FD:36:E6:E9:D2
              X509v3 Subject Alternative Name:
                  DNS:f29-0.ipa.local, othername:<unsupported>, othername:<unsupported>


Most CA programs, including Dogtag, automatically compute a SKI for
every certificate being issued.  Dogtag computes a SHA-1 hash over
the ``subjectPublicKey`` value, which is the most common method.
The value must be unique, but does not have to be derived from the
public key.

It is not required for a self-signed CA certificate to contain an
AKI extension.  Neither is it necessary to include a SKI in an end
entity certificate.  But it does not hurt to include them.  Indeed
it is common (as we see above).

Use case for specifying a SKI
-----------------------------

If CAs can automatically compute a SKI, why would you need to
specify one?

The use case arises when you're changing external CAs or switching
from self-signed to externally-signed, or vice versa.  The new CA
might compute SKIs differently from the current CA.  But it is
important to keep using the same SKI.  So it is desirable to include
the SKI in the CSR to indicate to the CA the value that should be
used.

Not every CA program will follow the suggestion.  Or the behaviour
may be configurable, system-wide or per-profile.  If you're using
Dogtag / RHCS to sign CA certificates, it is straightforward to
define a profile that uses an SKI supplied in the CSR (but that is
beyond the scope of this article).


Including an SKI in a Dogtag CSR
--------------------------------

At time of writing, this procedure is supported in Dogtag 10.6.9 and
later, which is available in Fedora 28 and Fedora 29.  It will be
supported in a future version of RHEL.  The behaviour depends on a
recent enhancement to the ``certutil`` program, which is part of
NSS.  That enhancement is not in RHEL 7 yet, hence this Dogtag
feature is not yet available on RHEL 7.

When installing Dogtag using the two-step external signing
procedure, by default no SKI is included the CSR.  You can change
this via the ``pki_req_ski`` option.  The option is described in the
``pki_default.cfg(5)`` man page.  There are two ways to use the
option, and we will look at each in turn.


Default method
^^^^^^^^^^^^^^

::

  [CA]
  pki_req_ski=DEFAULT

This special value will cause the CSR to contain a SKI value
computed using the same method Dogtag itself uses (SHA-1 digest).
Adding this value resulted in the following CSR data::

  Certificate Request:
      Data:
          Version: 1 (0x0)
          Subject: O = IPA.LOCAL 201903011502, CN = Certificate Authority
          Subject Public Key Info:
              < elided >
          Attributes:
          Requested Extensions:
              X509v3 Subject Key Identifier: 
                  76:49:AA:B2:08:60:18:C1:6D:AF:2C:28:A0:54:34:77:7E:8F:80:71
              X509v3 Basic Constraints: critical
                  CA:TRUE
              X509v3 Key Usage: critical
                  Digital Signature, Non Repudiation, Certificate Sign, CRL Sign

The SKI value is the SHA-1 digest of the public key.  Of course, it
will be different every time, because a different key will be
generated.


Explicit SKI
^^^^^^^^^^^^

::

  [CA]
  pki_req_ski=<hex data>

An exact SKI value can be specified as a hex-encode byte string.
The datum **must not** have a leading ``0x``.  I used the following
configuration::

  [CA]
  pki_req_ski=00D06F00D4D06746

With this configuration, the expected SKI value appears in the CSR::

  Certificate Request:
      Data:
          Version: 1 (0x0)
          Subject: O = IPA.LOCAL 201903011518, CN = Certificate Authority
          Subject Public Key Info:
              < elided >
          Attributes:
          Requested Extensions:
              X509v3 Subject Key Identifier:
                  00:D0:6F:00:D4:D0:67:46
              X509v3 Basic Constraints: critical
                  CA:TRUE
              X509v3 Key Usage: critical
                  Digital Signature, Non Repudiation, Certificate Sign, CRL Sign

Renewal
-------

We don't have direct support for including the SKI in the CSR
generated for renewing an externally signed CA.  But you can use
``certutil`` to create a CSR that includes the desired SKI.

It could be worthwhile to enhance Certmonger to automatically
include the SKI of the current certificate when it creates a CSR for
renewing a tracked certificate.


FreeIPA support
---------------

We don't expose this feature in FreeIPA directly.  It can be hacked
in pretty easily by modifying the Python code that builds the
``pkispawn`` configuration during installation.  Alternatively, set
the option in the ``pkispawn`` default configuration file:
``/usr/share/pki/server/etc/default.cfg`` (this is what I did to
test the feature).

Changes to be made as part of the `upcoming HSM support`_ will, as a
pleasant side effect, make it easy to specify or override
``pkispawn`` configuration values including ``pki_req_ski``.

.. _upcoming HSM support: https://github.com/freeipa/freeipa/pull/2307

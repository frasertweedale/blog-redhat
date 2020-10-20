---
tags: freeipa, certificates
---

Issuing certificates for long hostnames
=======================================

X.509, specified in `RFC 5280`_, restricts the length of the *Common
Name (CN)* attribute to 64 characters::

  X520CommonName ::= DirectoryName (SIZE (1..ub-common-name))
  ub-common-name-length INTEGER ::= 64

.. _RFC 5280: https://tools.ietf.org/html/rfc5280

Although the use of the CN attribute to carry DNS names is
deprecated, it is still common practice.  Furthermore, FreeIPA still
requires the CN to appear in a *Certificate Signing Request (CSR)*
and validates that its value corresponds to the nominated *subject
principal*.

As a consequence of this restriction, when a host or service has a
DNS name longer than 64 characters, that name cannot be used as the
CN.  But it can still be included in the *Subject Alternative Name*
extension, as a *dNSName* value.

How do we issue such a certificate in FreeIPA?  The trick is to add
a *principal alias* whose hostname is 64 characters or shorter.
This shorter hostname will be the Common Name attribute value.  The
full hostname will appear in the Subject Alternative Name extension.  

The following sections demonstrate the method.  I conclude with an
outline of what needs to be done to support certificates with empty
Subject DN, which would avoid the problem and this workaround.

Creating a principal with a long hostname
-----------------------------------------

To experiment and verify the workaround, I needed a principal with a
hostname longer than 64 characters.  The initial attempt failed::

  % ipa host-add --force \
      verylongverylongverylongverylongverylongverylonghostname.ipa.local
  ipa: ERROR: invalid 'hostname': can be at most 64 characters

FreeIPA has a default maximum hostname length of 64 characters, but
this is configurable.  After adjusting the limit, adding the host
succeeded::

  % ipa config-mod --maxhostname 255
    Maximum username length: 32
    Maximum hostname length: 255
    ...

  % ipa host-add --force \
      verylongverylongverylongverylongverylongverylonghostname.ipa.local
  -------------------------------------------------------------------------------
  Added host "verylongverylongverylongverylongverylongverylonghostname.ipa.local"
  -------------------------------------------------------------------------------
    Host name: verylongverylongverylongverylongverylongverylonghostname.ipa.local
    Principal name: host/verylongverylongverylongverylongverylongverylonghostname.ipa.local@IPA.LOCAL
    Principal alias: host/verylongverylongverylongverylongverylongverylonghostname.ipa.local@IPA.LOCAL
    ...

Adding the principal alias
--------------------------

For a host principal, use the ``ipa host-add-principal`` command to
add a principal alias.  The alias must also be a host principal,
i.e. must have the form ``host/$hostname``::

  % ipa host-add-principal \
      verylongverylongverylongverylongverylongverylonghostname.ipa.local \
      host/longhostname.ipa.local
  ----------------------------------------------------------------------------------------------
  Added new aliases to host "verylongverylongverylongverylongverylongverylonghostname.ipa.local"
  ----------------------------------------------------------------------------------------------
  Host name: verylongverylongverylongverylongverylongverylonghostname.ipa.local
  Principal alias: host/verylongverylongverylongverylongverylongverylonghostname.ipa.local@IPA.LOCAL,
                   host/longhostname.ipa.local@IPA.LOCAL

For a service principal, use the ``ipa service-add-principal``
command.  Ensure the principal alias has the same service type as
the subject principal's *canonical name* (i.e. the value its
``krbcanonicalname`` attribute).  For example, if the canonical
principal name is ``HTTP/$LONGHOSTNAME``, then the principal alias
should be ``HTTP/$SHORTHOSTNAME``.

I omitted the realm parts of principal names (the default realm will
be added automatically).  For the avoidance of doubt, the princpial
alias must have the same realm as the canonical principal.

Creating a CSR
--------------

There are many different ways to create a CSR.  I will give a single
example using OpenSSL.  The private key already exists (file
``key.pem``).

The configuration file::

  % cat longhostname.conf
  [ req ]
  prompt = no
  encrypt_key = no

  distinguished_name = dn
  req_extensions = exts

  [ dn ]
  commonName = "longhostname.ipa.local

  [ exts ]
  subjectAltName=DNS:verylongverylongverylongverylongverylongverylonghostname.ipa.local

Create the CSR::

  % openssl req -new -key key.pem \
      -config longhostname.conf -extensions exts \
      > longhostname.csr

Issuing the certificate
-----------------------

Now we can issue the certificate::

  % ipa cert-request longhostname.csr \
      --principal host/verylongverylongverylongverylongverylongverylonghostname.ipa.local
    Issuing CA: ipa
    Certificate: MIIE...
    Subject: CN=longhostname.ipa.local,O=IPA.LOCAL 202009291726
    Subject DNS name: verylongverylongverylongverylongverylongverylonghostname.ipa.local,
                      longhostname.ipa.local
    Issuer: CN=Certificate Authority,O=IPA.LOCAL 202009291726
    Not Before: Mon Oct 19 13:46:16 2020 UTC
    Not After: Thu Oct 20 13:46:16 2022 UTC
    Serial number: 11
    Serial number (hex): 0xB

The CN attribute contains the shorter host name, and the SAN
extension contains both the long and shorter hostnames.  (We did not
include the short hostname in the CSR SAN extension, but the
``CommonNameToSANDefault`` profile component copied it there).

Supporting SAN-only certificates
--------------------------------

This workaround is straightforward but it is not the ideal solution.
A better approach is to enhance FreeIPA and Dogtag to support
issuing certificates with an empty Subject DN, using only the
Subject Alternative Name extension to carry subject information.

RFC 5280 allows an empty Subject DN in a certificate, in which case
the certificate must include the SAN extension, which must be marked
as *critical*.  `RFC 6125`_ further clarifies that such a
certificate is acceptable for use with TLS.

.. _RFC 6125: https://tools.ietf.org/html/rfc6125#section-2.3

`Upstream ticket #5706`_ requests support for SAN-only certificates.
The work will involve:

- Change the ``ipa cert-request`` command to accept empty subjects.
  When the subject is empty ensure a non-empty SAN extension is
  present in the CSR, and that it is marked criticial.  This is
  straightforward.

- On the Dogtag side we must implement new behaviour in the request
  processor to ensure that the certificate to be issued satisfies
  the X.509 requirements about empty/non-empty Subject DN and the
  presence and criticality of the SAN extension.

- It may be necessary to define a new profile default or constraint
  component that allows an empty subject DN.

- It is likely that FreeIPA will need to either modify the default
  profile (``caIPAserviceCert``) to allow for an empty Subject DN,
  or ship a separate profile that is suitable.

.. _Upstream ticket #5706: https://pagure.io/freeipa/issue/5706

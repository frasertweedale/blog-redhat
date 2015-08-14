..
  Copyright 2015 Red Hat, Inc.

  This work is licensed under a
  Creative Commons Attribution 4.0 International License.

  You should have received a copy of the license along with this
  work. If not, see <http://creativecommons.org/licenses/by/4.0/>.


User certificates and custom profiles with FreeIPA 4.2
======================================================

The `FreeIPA 4.2`_ release introduces some long-awaited certificate
management features: user certificates and custom certificate
profiles.  In this blog post, we will examine the background and
motivations for these features, then carry out a real-world scenario
where both these features are used: user S/MIME certificates for
email protection.

.. _FreeIPA 4.2: http://www.freeipa.org/page/Releases/4.2.0

Custom profiles
---------------

FreeIPA uses the `Dogtag Certificate System`_ PKI for issuance of
X.509 certificates.  Although Dogtag ships with many *certificate
profiles*, and could be configured with profiles for almost any
conceivable use case, FreeIPA only used a single profile for the
issuance of certificates to service and host principals.  (The name
of this profile was ``caIPAserviceCert``, but it hardcoded and not
user-visible).

.. _Dogtag Certificate System: http://pki.fedoraproject.org/wiki/PKI_Main_Page

The ``caIPAserviceCert`` profile was suitable for the standard TLS
server authentication use case, but there are many use cases for
which it was not suitable; especially those that require particular
*Key Usage* or *Extended Key Usage* assertions or esoteric
certificate extensions, to say nothing of client-oriented profiles.

It was possible (and remains possible) to use the deployed Dogtag
instance directly to accomplish almost any certificate management
goal, but Dogtag lacks knowledge of the FreeIPA schema so the burden
of validating requests falls entirely on administrators.  This runs
contrary to FreeIPA's goal of easy administration and the
expectations of users.

The ``certprofile-import`` command allows new profiles to be
imported into Dogtag, while ``certprofile-mod``,
``certprofile-del``, ``certprofile-show`` and ``certprofile-find``
do what they say on the label.  Only profiles that are shipped as
part of FreeIPA (at time of writing only ``caIPAserviceCert``) or
added via ``certprofile-import`` are visible to FreeIPA.

An important per-profile configuration that affects FreeIPA is the
``ipaCertprofileStoreIssued`` attribute, which is exposed on the
command line as ``--store=BOOL``.  This attribute tells the
``cert-request`` command what to do with certificates issued using
that profile.  If ``TRUE``, certificates are added to the target
principal's ``userCertificate`` attribute; if ``FALSE``, the issued
certificate is delievered to the client in the command result but
nothing is stored in the FreeIPA directory (though the certificate
is still stored in Dogtag's database).  The option to *not* store
issued certificates is desirable in uses cases that involve the
issuance of many short-lived certificates.

Finally, ``cert-request`` learned the ``--profile-id`` option to
specify which profile to use.  It is optional and defaults to
``caIPAserviceCert``.


User certificates
-----------------

Prior to FreeIPA 4.2 certificates could only be issued for host and
service principals.  The same capability now exists for user
principals.  Although ``cert-request`` treats user principals in
substantially the same way as host or service principals there are
a few important differences:

- The subject *Common Name* in the certificate request must match
  the FreeIPA user name.

- The subject email address (if present) must match one of the
  user's email addresses.

- All Subject Alternative Name *rfc822Name* values must match one of
  the user's email addresses.

- Like services and hosts, *KRB5PrincipalName* SAN is permitted if
  it matches the principal.

- *dNSName* and other SAN types are prohibited.


CA ACLs
-------

With support for custom certificate profiles, there must be a way to
control which profiles can be used for issuing certificates to which
principals.  For example, if there was a profile for Puppet masters,
it would be sensible to restrict use of that profile to hosts that
are members of a some Puppet-related group.  This is the purpose of
*CA ACLs*.

CA ACLs are created with the ``caacl-add`` command.  Users and
groups can be added or removed with the ``caacl-add-user`` and
``caacl-remove-user`` commands.  Similarly,
``caacl-{add,remove}-host`` for hosts and hostgroups, and
``caacl-{add,remove}-service``.

If you are familiar with FreeIPA's *Host-based Access Control*
(HBAC) policy feature these commands might remind you of the
``hbacrule`` commands.  That is no coincidence!  The ``hbcarule``
commands were my guide for implementing the ``caacl`` commands, and
the same underlying machinery - ``libipa_hbac`` via ``pyhbac`` - is
used by both plugins to enforce their policies.


Putting it all together
-----------------------

Let's put these features to use with a realistic scenario.  A
certain group of users in your organisation must use S/MIME for
securing their email communications.  To use S/MIME, these users
must be issued a certificate with *emailProtection* asserted in the
Extended Key Usage certificate extension.  Only the
authorised users should be able to have such a certificate issued.

To address this scenario we will:

1. create a new certificate profile for S/MIME certificates;

2. create a group for S/MIME users and a CA ACL to allow members of
   that group access to the new profile;

3. generate a signing request and issue a ``cert-request`` command
   using the new profile.

Let's begin.

Creating an S/MIME profile
^^^^^^^^^^^^^^^^^^^^^^^^^^

We export the default profile to use as a starting point for the
S/MIME profile::

  % ipa certprofile-show --out smime.cfg caIPAserviceCert

Inspecting the profile, we find the *Extended Key Usage* extension
configuration containing the line::

  policyset.serverCertSet.7.default.params.exKeyUsageOIDs=1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2

The *Extended Key Usage* extension is defined in
`RFC 5280 §4.2.1.12`_.  The two OIDs in the default profile are for
*TLS WWW server authentication* and *TLS WWW client authentication*
respectively.  For S/MIME, we need to assert the *Email protection*
key usage, so we change this line to::

  policyset.serverCertSet.7.default.params.exKeyUsageOIDs=1.3.6.1.5.5.7.3.4

.. _RFC 5280 §4.2.1.12: http://tools.ietf.org/html/rfc5280#section-4.2.1.12

We also remove the ``profileId=caIPAserviceCert`` and set an
appropriate value for the ``desc`` and ``name`` fields.  Now we can
import the new profile::

  % ipa certprofile-import smime --file smime.cfg \
    --desc "S/MIME certificates" --store TRUE
  ------------------------
  Imported profile "smime"
  ------------------------
  Profile ID: smime
  Profile description: S/MIME certificates
  Store issued certificates: TRUE


Defining the CA ACL
^^^^^^^^^^^^^^^^^^^

We will define a new group for S/MIME users, and a CA ACL to allow
users in that group access to the ``smime`` profile::

  % ipa group-add smime_users
  -------------------------
  Added group "smime_users"
  -------------------------
    Group name: smime_users
    GID: 1148600006

  % ipa caacl-add smime_acl
  ------------------------
  Added CA ACL "smime_acl"
  ------------------------
    ACL name: smime_acl
    Enabled: TRUE

  % ipa caacl-add-user smime_acl --group smime_users
    ACL name: smime_acl
    Enabled: TRUE
    User Groups: smime_users
  -------------------------
  Number of members added 1
  -------------------------

  % ipa caacl-add-profile smime_acl --certprofile smime
    ACL name: smime_acl
    Enabled: TRUE
    Profiles: smime
    User Groups: smime_users
  -------------------------
  Number of members added 1
  -------------------------


Creating and issuing a cert request
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Finally we need to create a PKCS #10 certificate signing request
(CSR) and issue a certificate via the ``cert-request`` command.  We
will do this for the user ``alice``.  Because this certificate is
for email protection Alice's email address should be in the *Subject
Alternative Name* (SAN) extension; we must include it in the CSR.

The following OpenSSL config file can be used to generate the
certificate request::

  [ req ]
  prompt = no
  encrypt_key = no

  distinguished_name = dn
  req_extensions = exts

  [ dn ]
  commonName = "alice"

  [ exts ]
  subjectAltName=email:alice@ipa.local

We create and then inspect the CSR (the ``genrsa`` step can be
skipped if you already have a key)::

  % openssl genrsa -out key.pem 2048
  Generating RSA private key, 2048 bit long modulus
  .........................+++
  ......+++
  e is 65537 (0x10001)
  % openssl req -new -key key.pem -out alice.csr -config alice.conf
  % openssl req -text < alice.csr
  Certificate Request:
      Data:
          Version: 0 (0x0)
          Subject: CN=alice
          Subject Public Key Info:
              Public Key Algorithm: rsaEncryption
                  Public-Key: (1024 bit)
                  Modulus:
                      00:da:62:61:b4:42:ee:bd:ff:e0:63:cb:ec:85:af:
                      5d:40:ab:59:98:cf:a2:ad:2a:2d:30:c4:73:dc:28:
                      92:45:d4:12:b2:fc:49:78:e2:03:42:d3:eb:69:4f:
                      33:d2:0c:db:22:6c:19:63:46:46:52:4c:4a:bc:93:
                      c6:1b:81:2b:8c:7b:5c:21:1d:5b:e5:5f:97:12:e3:
                      2b:d5:1f:93:99:c9:42:5e:a1:88:77:b1:4f:97:e2:
                      06:20:8b:eb:b7:0d:af:b8:7a:75:10:7a:0f:42:9b:
                      28:55:4c:e3:12:9f:2a:97:92:ab:f6:53:26:51:32:
                      88:f5:01:7f:e0:45:30:d9:51
                  Exponent: 65537 (0x10001)
          Attributes:
          Requested Extensions:
              X509v3 Subject Alternative Name: 
                  email:alice@ipa.local
      Signature Algorithm: sha1WithRSAEncryption
           1d:e3:dc:a8:af:6c:42:55:40:1a:88:a3:1f:c3:b7:2b:01:3a:
           8f:1f:80:b5:1c:de:80:53:f3:fc:61:91:16:03:3d:79:3a:4b:
           ee:0d:c0:09:1a:d9:d7:40:6e:05:7a:43:c1:0b:26:0c:22:0e:
           79:d1:b0:27:8d:9a:26:51:d5:1b:1b:46:e7:b5:03:97:51:ec:
           53:ae:dd:52:85:d3:48:8a:ac:cc:c0:84:61:9a:97:2e:25:1b:
           b1:f0:72:1f:73:94:3c:44:d5:12:1e:b5:b5:37:9b:57:5d:08:
           d8:52:d4:e5:52:05:17:cc:5f:28:ad:ac:0c:4c:36:dc:33:c2:
           11:6d
  -----BEGIN CERTIFICATE REQUEST-----
  MIIBfDCB5gIBADAQMQ4wDAYDVQQDDAVhbGljZTCBnzANBgkqhkiG9w0BAQEFAAOB
  jQAwgYkCgYEA2mJhtELuvf/gY8vsha9dQKtZmM+irSotMMRz3CiSRdQSsvxJeOID
  QtPraU8z0gzbImwZY0ZGUkxKvJPGG4ErjHtcIR1b5V+XEuMr1R+TmclCXqGId7FP
  l+IGIIvrtw2vuHp1EHoPQpsoVUzjEp8ql5Kr9lMmUTKI9QF/4EUw2VECAwEAAaAt
  MCsGCSqGSIb3DQEJDjEeMBwwGgYDVR0RBBMwEYEPYWxpY2VAaXBhLmxvY2FsMA0G
  CSqGSIb3DQEBBQUAA4GBAB3j3KivbEJVQBqIox/DtysBOo8fgLUc3oBT8/xhkRYD
  PXk6S+4NwAka2ddAbgV6Q8ELJgwiDnnRsCeNmiZR1RsbRue1A5dR7FOu3VKF00iK
  rMzAhGGaly4lG7Hwch9zlDxE1RIetbU3m1ddCNhS1OVSBRfMXyitrAxMNtwzwhFt
  -----END CERTIFICATE REQUEST-----

Observe that the common name is the user's name ``alice``, and that
``alice@ipa.local`` is present as an *rfc822Name* in the SAN
extension.

Now let's request the certificate::

  % ipa cert-request alice.req --principal alice --profile-id smime
  ipa: ERROR: Insufficient access: Principal 'alice' is not
    permitted to use CA '.' with profile 'smime' for certificate
    issuance.

Oops!  The CA ACL policy prohibited this issuance because we forgot
to add ``alice`` to the ``smime_users`` group.  (The ``not permitted
to use CA '.'`` part is a reference to the upcoming sub-CAs
feature).  Let's add the user to the appropriate group and try
again::

  % ipa group-add-member smime_users --user alice
    Group name: smime_users
    GID: 1148600006
    Member users: alice
  -------------------------
  Number of members added 1
  -------------------------

  % ipa cert-request alice.req --principal alice --profile-id smime
    Certificate: MIIEJzCCAw+gAwIBAgIBEDANBgkqhkiG9w0BAQsFADBBMR...
    Subject: CN=alice,O=IPA.LOCAL 201507271443
    Issuer: CN=Certificate Authority,O=IPA.LOCAL 201507271443
    Not Before: Thu Aug 06 04:09:10 2015 UTC
    Not After: Sun Aug 06 04:09:10 2017 UTC
    Fingerprint (MD5): 9f:8e:e0:a3:c6:37:e0:a4:a5:e4:6b:d9:14:66:67:dd
    Fingerprint (SHA1): 57:6e:d5:07:8f:ef:d6:ac:36:b8:75:e0:6c:d7:4f:7d:f9:6c:ab:22
    Serial number: 16
    Serial number (hex): 0x10

Success! We can see that the certificate was added to the user's
``userCertificate`` attribute, or export the certificate to inspect it (parts
of the certificate are elided below) or import it into an email program::

  % ipa user-show alice
    User login: alice
    First name: Alice
    Last name: Able
    Home directory: /home/alice
    Login shell: /bin/sh
    Email address: alice@ipa.local
    UID: 1148600001
    GID: 1148600001
    Certificate: MIIEJzCCAw+gAwIBAgIBEDANBgkqhkiG9w0BAQsFADBBMR...
    Account disabled: False
    Password: True
    Member of groups: smime_users, ipausers
    Kerberos keys available: True

  % ipa cert-show 16 --out alice.pem >/dev/null
  % openssl x509 -text < alice.pem
  Certificate:
      Data:
          Version: 3 (0x2)
          Serial Number: 16 (0x10)
      Signature Algorithm: sha256WithRSAEncryption
          Issuer: O=IPA.LOCAL 201507271443, CN=Certificate Authority
          Validity
              Not Before: Aug  6 04:09:10 2015 GMT
              Not After : Aug  6 04:09:10 2017 GMT
          Subject: O=IPA.LOCAL 201507271443, CN=alice
          Subject Public Key Info:
              Public Key Algorithm: rsaEncryption
                  Public-Key: (2048 bit)
                  Modulus:
                      00:e2:1b:92:06:16:f7:27:c8:59:8b:45:93:60:84:
                      ...
                      34:6f
                  Exponent: 65537 (0x10001)
          X509v3 extensions:
              X509v3 Authority Key Identifier: 
                  keyid:CA:19:15:12:87:04:70:6E:81:7B:1D:8D:C6:4A:F6:A1:49:AA:0D:45

              Authority Information Access: 
                  OCSP - URI:http://ipa-ca.ipa.local/ca/ocsp

              X509v3 Key Usage: critical
                  Digital Signature, Non Repudiation, Key Encipherment, Data Encipherment
              X509v3 Extended Key Usage: 
                  E-mail Protection
              X509v3 CRL Distribution Points: 

                  Full Name:
                    URI:http://ipa-ca.ipa.local/ipa/crl/MasterCRL.bin
                  CRL Issuer:
                    DirName: O = ipaca, CN = Certificate Authority

              X509v3 Subject Key Identifier: 
                  CE:A5:E3:B0:45:23:EC:B3:13:7C:BC:05:72:42:12:AD:9B:17:11:26
              X509v3 Subject Alternative Name: 
                  email:alice@ipa.local
      Signature Algorithm: sha256WithRSAEncryption
           29:6a:99:84:8e:46:dc:0e:42:3d:b2:3e:fc:3f:c4:46:dc:44:
           ...

Conclusion
----------

The ability to define and control access to custom certificate
profiles and the extension of FreeIPA's certificate management
features to user principals open the door to many use cases that
were previously not supported.  Although the certificate management
features available in FreeIPA 4.2 are a big step forward, there are
still several areas for improvement, outlined below.

First, the Dogtag certificate profile format is obtuse.
Documentation will make it bearable, but documentation is no
substitute for good UX.  An *interactive profile builder* would be a
complex feature to implement but we might go there.  Alternatively,
a public, curated, searchable (even from FreeIPA's web UI)
repository of profiles for various use cases might be a better use
of resources and would allow users and customers to help each other.

Next, the ability to create and use sub-CAs is an oft-requested
feature and important for *many* use cases.  Work is ongoing to
bring this to FreeIPA soon.  See the `Sub-CAs design page
<http://www.freeipa.org/page/V4/Sub-CAs>`_ for details.

Thirdly, the FreeIPA framework currently has authority to perform
all kinds of privileged operations on the Dogtag instance.  This
runs contrary to the framework philosophy which advocates for the
framework only having the privileges of the current user, with ACIs
(and CA ACLs) enforced in the backends (in this case Dogtag).
`Ticket #5011`_ was filed to address this discrepancy.

.. _Ticket #5011: https://fedorahosted.org/freeipa/ticket/5011

Finally, the request interface between FreeIPA and Dogtag is quite
limited; the only substantive information conveyed is whatever is in
the CSR.  There is minimal capability for FreeIPA to convey
additional data with a request, and any time we (or a user or
customer) want to broaden the interface to support new kinds of data
(e.g. esoteric certificate extensions containing values from custom
attributes), changes would have to be made to both FreeIPA and
Dogtag.  This approach does not scale.

I have a vision for how to address this final point in a future
version of FreeIPA.  It will be the subject of future blog posts,
talks and eventually - hopefully - design proposals and patches!
For now, I hope you have enjoyed this introduction to some of the
new certificate management capabilities in FreeIPA 4.2 and find them
useful.  And remember that feedback, bug reports and help with
development are always appreciated!

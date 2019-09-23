---
tags: certificates, integration, howto
---

Requesting certificates from FreeIPA on Active Directory clients
================================================================

In recent times I have seen some support cases and sales inquiries
about getting certificates on Linux systems that are enrolled in
Active Directory (AD).  Linux hosts can be directly enrolled in AD
via ``realmd`` or ``adcli``.  On AD-enrolled machines, SSSD can
provide authentication services, access control and some Group
Policy enforcement (see ``sssd-ad(5)``).  At Red Hat we call this
approach *direct integration*.  The alternative approach is to enrol
hosts in a FreeIPA / IDM realm, and use *cross-realm trusts* to
allow AD users/principals to authenticate to FreeIPA services, or
vice-versa.

Unfortunately when it comes to getting certificates from AD-CS (the
Active Directory certificate authority component) we don't have a
good story yet.  Certmonger lacks an out-of-the-box capability to
talk to AD-CS (except via SCEP, but that is not what we want).  I do
not know how much work would be involved in writing an AD-CS request
helper for Certmonger.  It might be a large effort or small; the
little AD-CS enrolment documentation I have found is hard to
penetrate.  But even if we could write the AD-CS helper and ship it
tomorrow, it would not help users and customers on older releases.  

For now the best solution is to deploy FreeIPA / IDM, and use the
IPA CA to issue certificates to AD-enrolled hosts.  In this
HOWTO-style post I walk through this scenario with a RHEL 6 client.

Environment
-----------

My local Windows Server 2012 R2 server defines the ``AD.LOCAL``
Active Directory (AD) realm.  The DNS zone is ``ad.local``.  I
configured a DNS *Conditional Forwarder* for ``ipa.local``,
delegating that namespace to the FreeIPA DNS server.

The FreeIPA server is ``rhel76-0.ipa.local``.  There is no AD trust.
The integrated DNS is in use so KDC discovery will work.

In a typical scenario the IPA CA might be a subordinate of the AD
CA.  In my setup the IPA CA is self-signed.  Operationally there is
one additional step when the IPA CA is not subordinate to the AD CA:
the IPA CA certificate has to be explicitly trusted.  To trust the
certificate copy it to a file under
``/etc/pki/ca-trust/source/anchors/`` then execute
``update-ca-trust``.

The RHEL 6 host is named ``rhel610-0.ipa.local`` The packages
required were ``adcli`` and ``ipa-client``.  On RHEL 7 and later or
Fedora the ``realm`` command, which is provided by the ``realmd``
package, is a better choice than ``adcli``.  ``/etc/resolv.conf``
points to the Windows Server.


Active Directory enrolment
--------------------------

I used the ``adcli`` command to enrol ``rhel610-0`` in Active
Directory::

  [root@rhel610-0 ~]# adcli join ad.local --show-details
  Password for Administrator@AD.LOCAL: XXXXXXXX
  [domain]
  domain-name = ad.local
  domain-realm = AD.LOCAL
  domain-controller = win-ppk015f9mdq.ad.local
  domain-short = AD
  domain-SID = S-1-5-21-3519545429-1027502194-913185514
  naming-context = DC=ad,DC=local
  domain-ou = (null)
  [computer]
  host-fqdn = rhel610-0.ipa.local
  computer-name = RHEL610-0
  computer-dn = CN=RHEL610-0,CN=Computers,DC=ad,DC=local
  os-name = redhat-linux-gnu
  [keytab]
  kvno = 2
  keytab = FILE:/etc/krb5.keytab

The output shows that the enrolment succeeded and prints information
about the realm and enrolment.  Inspecting the system keytab
``/etc/krb5.keytab`` shows the Kerberos keys::

  [root@rhel610-0 ~]# ktutil
  ktutil:  read_kt /etc/krb5.keytab
  ktutil:  list
  slot KVNO Principal
  ---- ---- ---------------------------------------------------------------------
     1    2                      RHEL610-0$@AD.LOCAL
     2    2                      RHEL610-0$@AD.LOCAL
     3    2                      RHEL610-0$@AD.LOCAL
     4    2                      RHEL610-0$@AD.LOCAL
     5    2                      RHEL610-0$@AD.LOCAL
     6    2                      RHEL610-0$@AD.LOCAL
     7    2                  host/RHEL610-0@AD.LOCAL
     8    2                  host/RHEL610-0@AD.LOCAL
     9    2                  host/RHEL610-0@AD.LOCAL
    10    2                  host/RHEL610-0@AD.LOCAL
    11    2                  host/RHEL610-0@AD.LOCAL
    12    2                  host/RHEL610-0@AD.LOCAL
    13    2        host/rhel610-0.ipa.local@AD.LOCAL
    14    2        host/rhel610-0.ipa.local@AD.LOCAL
    15    2        host/rhel610-0.ipa.local@AD.LOCAL
    16    2        host/rhel610-0.ipa.local@AD.LOCAL
    17    2        host/rhel610-0.ipa.local@AD.LOCAL
    18    2        host/rhel610-0.ipa.local@AD.LOCAL
    19    2     RestrictedKrbHost/RHEL610-0@AD.LOCAL
    20    2     RestrictedKrbHost/RHEL610-0@AD.LOCAL
    21    2     RestrictedKrbHost/RHEL610-0@AD.LOCAL
    22    2     RestrictedKrbHost/RHEL610-0@AD.LOCAL
    23    2     RestrictedKrbHost/RHEL610-0@AD.LOCAL
    24    2     RestrictedKrbHost/RHEL610-0@AD.LOCAL
    25    2 RestrictedKrbHost/rhel610-0.ipa.local@AD.LOCAL
    26    2 RestrictedKrbHost/rhel610-0.ipa.local@AD.LOCAL
    27    2 RestrictedKrbHost/rhel610-0.ipa.local@AD.LOCAL
    28    2 RestrictedKrbHost/rhel610-0.ipa.local@AD.LOCAL
    29    2 RestrictedKrbHost/rhel610-0.ipa.local@AD.LOCAL
    30    2 RestrictedKrbHost/rhel610-0.ipa.local@AD.LOCAL
  ktutil:  quit


FreeIPA "enrolment"
-------------------

Next I created a host princpial for ``rhel610-0.ipa.local`` in the
FreeIPA realm::

  [root@rhel76-0 ~]# ipa host-add rhel610-0.ipa.local
  --------------------------------
  Added host "rhel610-0.ipa.local"
  --------------------------------
    Host name: rhel610-0.ipa.local
    Principal name: host/rhel610-0.ipa.local@IPA.LOCAL
    Principal alias: host/rhel610-0.ipa.local@IPA.LOCAL
    Password: False
    Keytab: False
    Managed by: rhel610-0.ipa.local

Because the integrated DNS is in use, we do not need to explicitly
tell the Kerberos library about the ``IPA.LOCAL`` KDC.  Instead you
only need to ensure that ``/etc/krb5.conf`` **does not contain**::

  [libdefaults]
    dns_lookup_kdc = false

When not using KDC discovery a section like the following is
needed::

  [realms]
   IPA.LOCAL = {
    kdc = rhel76-0.ipa.local
    admin_server = rhel76-0.ipa.local
   }

I also needed to add a ``[domain_realm]`` section to tell the
Kerberos client library what realm to use when talking to the IPA
server::

  [domain_realm]
   .ipa.local = IPA.LOCAL

Reading ``krb5.conf(5)``, there is a ``[libdefaults]`` knob called
``realm_try_domains``.  From the description, it seems that using it
could avoid the need for a ``[domain_realm]`` section.  But it did
not work for me, in the way I expected (on this RHEL 6 client at
least).

Next I had to retrieve the host keys for the ``IPA.LOCAL`` realm
into the system keytab.  The Certmonger IPA helper will use those
keys to authenticate to FreeIPA when requesting a certificate::

  [root@rhel610-0 ~]# kinit admin@IPA.LOCAL
  Password for admin@IPA.LOCAL: 
  [root@rhel610-0 ~]# ipa-getkeytab -s rhel76-0.ipa.local \
      -p host/rhel610-0.ipa.local@IPA.LOCAL \
      -k /etc/krb5.keytab
  Keytab successfully retrieved and stored in: /etc/krb5.keytab

Listing the keys in ``/etc/krb5.conf`` we now see that the
``IPA.LOCAL`` host keys have been *appended*::

  [root@rhel610-0 ~]# ktutil
  ktutil:  read_kt /etc/krb5.keytab
  ktutil:  list
  slot KVNO Principal
  ---- ---- ---------------------------------------------------------------------
     1    2                      RHEL610-0$@AD.LOCAL
      ...
    30    2 RestrictedKrbHost/rhel610-0.ipa.local@AD.LOCAL
    31    1       host/rhel610-0.ipa.local@IPA.LOCAL
    32    1       host/rhel610-0.ipa.local@IPA.LOCAL
    33    1       host/rhel610-0.ipa.local@IPA.LOCAL
    34    1       host/rhel610-0.ipa.local@IPA.LOCAL
  ktutil:  quit


SELinux considerations
----------------------

I will store certificates and keys under ``/etc/pki/tls/private/``
because this directory has the correct SELinux context (and default
context rules) for Certmonger to use it::

  [root@rhel610-0 ~]# ls -l -d -Z /etc/pki/tls/private/
  drwxr-xr-x. root root system_u:object_r:cert_t:s0 /etc/pki/tls/private/

If you want Certmonger to manage keys and certificates in other
directories you need to ensure the files/directory have the
``cert_t`` type label.  This can be achieved via the ``semanage(8)``
and ``restorecon(8)``, but I will not go into further detail here.


Certmonger IPA configuration
----------------------------

Certmonger comes out of the box with a request/renewal helper for an
IPA CA.  But it assumes that the client is an IPA-enrolled server,
i.e. per ``ipa-client-install``.  In particular there are two files
that must be manually set up.  First, the IPA CA (and chain) must be
present in ``/etc/ipa/ca.crt``.  It can be copied from the IPA
server without changes.  I have filed a ticket to `make Certmonger
use the system CA trust store`_.

.. _make Certmonger use the system CA trust store: https://pagure.io/certmonger/issue/132

The other file is ``/etc/ipa/default.conf``.  The Certmonger IPA
helper reads several fields from this file to locate the IPA server
and work out how to initialise Kerberos credentials.  I used the
following configuration::

  [global]
  server = rhel76-0.ipa.local
  basedn = dc=ipa,dc=local
  realm = IPA.LOCAL
  domain = ipa.local
  xmlrpc_uri = https://rhel76-0.ipa.local/ipa/xml
  ldap_uri = ldaps://rhel76-0.ipa.local


Requesting the certificate
--------------------------

Now we can tell Certmonger to request a certificate using the IPA
CA::

  [root@rhel610-0 ~]# getcert request \
      -c IPA \
      -k /etc/pki/tls/private/cert.key \
      -f /etc/pki/tls/private/cert.pem \
      -K host/rhel610-0.ipa.local@IPA.LOCAL \
      -D rhel610-0.ipa.local
  New signing request "20190920053226" added.

The options used are:

``-c``
  Use the ``IPA`` CA request/renewal helper.  To see a list of all
  the defined CA helpers execute ``getcert list-cas``.

``-k``
  Where to store the newly generated, or read the existing, private
  key.

``-f``
  Where to store the issued certificate.

``-K``

  Kerberos principal name, which will appear in the CSR's Subject
  Alternative Name extension.  The ``IPA`` request helper requires
  this parameter.

``-D``
  DNS name to include in the Subject Alternative Name extension.


We can use the request ID to print the details of the certificate
request::

  [root@rhel610-0 ~]# getcert list -i 20190920053226
  Number of certificates and requests being tracked: 1.
  Request ID '20190920053226':
    status: MONITORING
    stuck: no
    key pair storage: type=FILE,location='/etc/pki/tls/private/cert.key'
    certificate: type=FILE,location='/etc/pki/tls/private/cert.pem'
    CA: IPA
    issuer: CN=Certificate Authority,O=IPA.LOCAL 201909191314
    subject: CN=rhel610-0.ipa.local,O=IPA.LOCAL 201909191314
    expires: 2021-09-23 09:34:49 UTC
    dns: rhel610-0.ipa.local
    principal name: host/rhel610-0.ipa.local@IPA.LOCAL
    key usage: digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
    eku: id-kp-serverAuth,id-kp-clientAuth
    pre-save command: 
    post-save command: 
    track: yes
    auto-renew: yes

The ``MONITORING`` status shows that the initial certificate request
was successful.  Certmonger is now tracking the certificate and will
attempt to renew it when its ``notAfter`` (expiration) time
approaches.  We can also pretty-print the certificate to see the
gory details::

  [root@rhel610-0 ~]# openssl x509 -text -noout \
      < /etc/pki/tls/private/cert.pem
  Certificate:
      Data:
          Version: 3 (0x2)
          Serial Number: 19 (0x13)
      Signature Algorithm: sha256WithRSAEncryption
          Issuer: O=IPA.LOCAL 201909191314, CN=Certificate Authority
          Validity
              Not Before: Sep 23 09:34:49 2019 GMT
              Not After : Sep 23 09:34:49 2021 GMT
          Subject: O=IPA.LOCAL 201909191314, CN=rhel610-0.ipa.local
          Subject Public Key Info:
              Public Key Algorithm: rsaEncryption
                  Public-Key: (2048 bit)
                  Modulus:
                      00:da:ca:ca:08:d5:da:d5:79:9e:46:49:85:3f:c9:
                      ... <snip>
                  Exponent: 65537 (0x10001)
          X509v3 extensions:
              X509v3 Authority Key Identifier: 
                  keyid:DB:24:C2:6B:51:FD:F7:6B:25:79:6B:37:23:02:51:05:07:52:2D:39

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
                    DirName: O = ipaca, CN = Certificate Authority

              X509v3 Subject Key Identifier: 
                  87:71:B3:6C:1D:9B:B9:7E:9D:2E:25:B0:CC:68:A4:92:FA:EE:33:C3
              X509v3 Subject Alternative Name: 
                  DNS:rhel610-0.ipa.local, othername:<unsupported>, othername:<unsupported>
      Signature Algorithm: sha256WithRSAEncryption
           5e:36:e3:21:c3:14:7f:d9:1c:c1:ac:7e:12:3e:6b:34:76:a6:
           ... <snip>


Conclusion
----------

I have shown how AD-enrolled Linux hosts can request certificates
from FreeIPA.  Reviewing the major considerations and steps:

1. Create a host principal in the FreeIPA realm
2. Retrieve the keytab
3. Adjust ``/etc/krb5.conf`` for the FreeIPA realm (DNS-based KDC
   discovery means there is less to do)
4. Add IPA CA certificate to ``/etc/ipa/ca.crt`` and add
   ``/etc/ipa/default.conf``; these are needed by the Certmonger
   request helper
5. Request certificate (some SELinux-fu needed if storing certs/keys
   in non-default locations)

The exact steps were for a RHEL 6 machine.  The procedure may differ
for newer systems, but not in any big ways.

In the course of exploring the procedure for this post I found it
helpful to invoke the Certmonger IPA helper directly, e.g.::

  [root@rhel610-0 ~]# /usr/libexec/certmonger/ipa-submit \
      -P host/rhel610-0.ipa.local@IPA.LOCAL foo.req
  Submitting request to "https://rhel76-0.ipa.local/ipa/xml".
  Fault 3009: (RPC failed at server.  invalid 'csr': hostname in
    subject of request 'freebsd10-0.ipa.local' does not match name
    or aliases of principal 'host/rhel610-0.ipa.local@IPA.LOCAL').
  Server at https://rhel76-0.ipa.local/ipa/xml denied our request,
    giving up: 3009 (RPC failed at server.  invalid 'csr': hostname
    in subject of request 'freebsd10-0.ipa.local' does not match
    name or aliases of principal 'host/rhel610-0.ipa.local@IPA.LOCAL').

In the preceding example, I invoked the helper directly, supplying a
(bogus) CSR and specifying the subject principal.  The goal was not
to successfully request a certificate but to verify the Kerberos
configuration.  If you are trying to use the IPA helper on a
non-IPA-enrolled system you may also find this approach helpful for
diagnosing issues.

Newer releases of Certmonger added support for requesting
certificates using a different certificate profile, or a different
IPA (sub-)CA.  On RHEL 6, it is not possible to request a different
profile so the default profile (``caIPAserviceCert``) is always
used.  IPA server on RHEL 7 and later does support modifying
profiles, including the default profile.

The Certmonger IPA request helper uses ``/etc/ipa/ca.crt`` as the
trust store for the HTTPS requests it makes to the FreeIPA server.
If the IPA CA certificate is updated, this file will have to be
updated on clients.  When there are systems not IPA-enrolled á la
``ipa-client-install``, it may be worthwhile to use configuration
management tools such as Ansible to do this.

As for getting certificates from AD-CS directly, there is interest
from users and customers.  I would like to see it implemented, but
when or by whom, or whether we even will, has not been decided as of
September 2019.

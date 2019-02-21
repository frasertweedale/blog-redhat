---
tags: freeipa, certificates, howto
---

IP address SAN support in FreeIPA
=================================

The X.509 *Subject Alternative Name (SAN)* certificate extension
carries subject names that cannot (or cannot easily) be expressed in
the Subject Distinguished Name field.  The extension supports
various name types, including DNS names (the most common), IP
addresses, email addresses (for users) and Kerberos principal names,
among others.

When issuing a certificate, FreeIPA has to validate that requested
SAN name values match the principal to whom the certificate is being
issued.  There has long been support for DNS names, Kerberos and
Microsoft principal names, and email addresses.  Over the years we
have received many requests to support IP address SAN names.  And
now we are finally `adding support`_!

In this post I will explain the context and history of this feature,
and demonstrate how to use it.  At time of writing the work is `not
yet merged`_, but substantive changes are not expected.

.. _adding support: https://pagure.io/freeipa/issue/7451
.. _not yet merged: https://github.com/freeipa/freeipa/pull/1843


Acknowledgement
---------------

First and foremost, I must thank **Ian Pilcher** who drove this
work.  DNS name validation is tricky, but Ian proposed a regime that
was acceptable to the FreeIPA team from a philosophical and security
standpoint.  Then he cut the initial patch for the feature.  The
work was of a high quality; my subsequent changes and enhancements
were minor.  Above all, Ian and others had great patience as the
pull request sat in limbo for nearly a year!  Thank you Ian.


IP address validation
---------------------

There is a reason we kicked the SAN IP address support can down the
road for so long.  Unlike some name types, validating IP addresses
is far from straightforward.

Let's first consider the already-supported name types.  FreeIPA is
an *identity management system*.  It *knows* the various identities
(principal name, email address, hostname) of the subjects/principals
it knows about.  Validation of these name types reduces to the
question *"does this name belong to the subject principal object?"*

For IP addresses is not so simple.  There are several complicating
factors:

- FreeIPA *can* manage DNS entries, but it doesn't have to.  If
  FreeIPA is not a source of authoritative DNS information, should
  it trust information from external resolvers?  Only with DNSSEC?

- There may be multiple, conflicting sources of DNS records.  The
  DNS *view* presented to FreeIPA clients may differ from that
  seen by other clients.  The FreeIPA DNS may "shadow" public (or
  other) DNS records.

- For validation, what should be the treatment of forward (``A`` /
  ``AAAA``) and reverse (``PTR``) records pertaining to the names
  involved?

- Should ``CNAME`` records be followed?  How many times?

- The issued certificate may be used in or presented to clients in
  environments with a different DNS view from the environment in
  which validation was performed.

- Does the request have to come from, or does the requesting entity
  have to prove control of, the IP address(es) requested for
  inclusion in the certificate?

- IP addresses often change and a reassigned much more often than
  the typical lifetime of a certificate.

- If you query external DNS systems, how do you handle failures or
  slowness?

- The need to mitigate DNS or BGP poisoning attacks

Taking these factors into account, it is plain to see why we put
this feature off for so long.  It is just hard to determine what the
correct behaviour should be.  Nevertheless use cases exist so the
feature request is legitimate.  The difference with `Ian's RFE` was
that he proposed a strict validation regime that only uses data
defined in FreeIPA.  It is a fair assumption that the data managed
by a FreeIPA instance is *trustworthy*.  That assumption, combined
with some sanity checks, gives the validation requirements:

1. Only FreeIPA-managed DNS records are considered.  There is no
   communication with external DNS resolvers.

2. For each IP address in the SAN, there is a DNS name in the SAN
   that resolves to it.  (As an implementation decision, we permit
   one level of CNAME indirection).

3. For each IP address in the SAN, there is a valid PTR (reverse
   DNS) record.

4. SAN IP addresses are only supported for host and service
   principals.

Requirement **1** avoids dealing with any conflicts or communication
issues with external resolvers.  Requirements **2** and **3**
together enforce a tight association between the subject principal
(every DNS name is verified to belong to it) and the IP address
(through forward and reverse resolution to the DNS name(s)).

.. _Ian's RFE: https://lists.fedoraproject.org/archives/list/freeipa-devel@lists.fedorahosted.org/thread/THFXEBXQ2W23O5Q7FWPA7XNMYA54D4PN/#5MFHNX4K35AKBSV2KUGZKON5SQ6GWEMI


Caveats and limitations
^^^^^^^^^^^^^^^^^^^^^^^

FreeIPA's SAN IP address validation regime leads to the following
caveats and limitations:

- The FreeIPA DNS component must be used.  (It can be enabled during
  installation, or at any time after installation.)

- Forward and reverse records of addresses to be included in
  certificates must be added and maintained.

- SAN IP addresses must be accompanied by at least one DNS name.
  Requests with *only* IP addresses will be rejected.


SAN IP address names in general have some limitations, too:

- The addresses in the certificate were correct at validation time,
  but might have changed.  The only mitigations are to use
  short-lived certificates, or revoke certificates if DNS changes
  render them invalid.  There is no detection or automation to
  assist with that.

- The certificate could be misused by services in other networks
  with the same IP address.  A well-behaved client would still have
  to trust the FreeIPA CA in order for this impersonation attack to
  work.


Comparison with the public PKI
------------------------------

SAN IP address names are supported by browsers.  The CA/Browser
Forum's `Baseline Requirements`_ permit publicly-trusted CAs to
issue end-entity certificates with SAN IP address values.  CAs have
to verify that the applicant controls (or has been granted the right
to use) the IP address.  There are several acceptable verification
methods:

1. The applicant make some agreed-upon change to a network resource
   at the IP address in question;

2. Consulting IANA or regional NIC assignment information;

3. Performing reverse lookup then verifying control over the DNS name.

The IETF *Automated Certificate Management Environment (ACME)*
working group has an `Internet-Draft for automated IP address
validation`_ in the ACME protocol.  It defines an automated approach
to method **1** above.  SAN IP addresses are `not yet supported`_ by
the most popular ACME CA, *Let's Encrypt* (and might never be).

.. _Baseline Requirements: https://cabforum.org/baseline-requirements-documents/
.. _Internet-Draft for automated IP address validation: https://tools.ietf.org/html/draft-ietf-acme-ip
.. _not yet supported: https://community.letsencrypt.org/t/certificate-for-public-ip-without-domain-name/6082/91

Depending on an organisation's security goals, the verification
methods mentioned above may or may not be appropriate for enterprise
use (i.e. behind the firewall).  Likewise, the decision about
whether a particular kind of validation could or should be automated
might have different answers for different organisations.  It is not
really a question of technical constraints; rather, one of
philosophy and security doctrine.  When it comes to certificate
request validation, the public PKI and FreeIPA are asking different
questions:

- FreeIPA asks: *does the indicated subject principal own the
  requested names?*

- The public PKI asks: *does the (potentially anonymous) applicant
  control the names they're requestion?*

In a few words, it's *ownership* versus *control*.  In the future it
might be possible for a FreeIPA CA to ask the latter question and
issue certificates (or not) accordingly.  But that isn't the focus
right now.


Demonstration
-------------

Preliminaries
^^^^^^^^^^^^^

The scene is set.  Let's see this feature in action!  The domain of
my FreeIPA deployment is ``ipa.local``.  I will add a host called
``iptest.example.com``, with the IP address ``192.168.2.1``.  The
first step is to add the reverse zone for this IP address::

  % ipa dnszone-add --name-from-ip 192.168.2.1
  Zone name [2.168.192.in-addr.arpa.]:
    Zone name: 2.168.192.in-addr.arpa.
    Active zone: TRUE
    Authoritative nameserver: f29-0.ipa.local.
    Administrator e-mail address: hostmaster
    SOA serial: 1550454790
    SOA refresh: 3600
    SOA retry: 900
    SOA expire: 1209600
    SOA minimum: 3600
    BIND update policy: grant IPA.LOCAL krb5-subdomain 2.168.192.in-addr.arpa. PTR;
    Dynamic update: FALSE
    Allow query: any;
    Allow transfer: none;

If the reverse zone for the IP address already exists, there would
be no need to do this first step.

Next I add the host entry.  Supplying ``--ip-address`` causes
forward and reverse records to be added for the supplied address
(assuming the relevant zones are managed by FreeIPA)::

  % ipa host-add iptest.ipa.local \
        --ip-address 192.168.2.1
  -----------------------------
  Added host "iptest.ipa.local"
  -----------------------------
    Host name: iptest.ipa.local
    Principal name: host/iptest.ipa.local@IPA.LOCAL
    Principal alias: host/iptest.ipa.local@IPA.LOCAL
    Password: False
    Keytab: False
    Managed by: iptest.ipa.local


CSR generation
^^^^^^^^^^^^^^

There are several options for creating a certificate signing request
(CSR) with IP addresses in the SAN extension.

- Lots of devices (routers, middleboxes, etc) generate CSRs
  containing their IP address.  This is the significant driving use
  case for this feature, but there's no point going into details
  because every device is different.

- The `Certmonger`_ utility makes it easy to add DNS names and IP
  addresses to a CSR, via command line arguments.  Several other
  name types are also supported.  See ``getcert-request(1)`` for
  details.

- OpenSSL requires a config file to specify SAN values for inclusing
  in CSRs and certificates.  See ``req(1)`` and ``x509v3_config(5)``
  for details.

- The NSS ``certutil(1)`` command provides the ``--extSAN`` option
  for specifying SAN names, including DNS names and IP addresses.

.. _Certmonger: https://pagure.io/certmonger

For this demonstration I use NSS and ``certutil``.  First I
initialise a new certificate database::

  % mkdir nssdb ; cd nssdb ; certutil -d . -N
  Enter a password which will be used to encrypt your keys.
  The password should be at least 8 characters long,
  and should contain at least one non-alphabetic character.

  Enter new password:
  Re-enter password:

Next, I generate a key and create CSR with the desired names in the
SAN extension.  We do not specify a key type or size we get the
default (2048-bit RSA).

::

  % certutil -d . -R -a -o ip.csr \
        -s CN=iptest.ipa.local \
        --extSAN dns:iptest.ipa.local,ip:192.168.2.1
  Enter Password or Pin for "NSS Certificate DB":

  A random seed must be generated that will be used in the
  creation of your key.  One of the easiest ways to create a
  random seed is to use the timing of keystrokes on a keyboard.

  To begin, type keys on the keyboard until this progress meter
  is full.  DO NOT USE THE AUTOREPEAT FUNCTION ON YOUR KEYBOARD!


  Continue typing until the progress meter is full:

  |************************************************************|

  Finished.  Press enter to continue:


  Generating key.  This may take a few moments...

The output file ``ip.csr`` contains the generated CSR.  Let's use
OpenSSL to pretty-print it::

  % openssl req -text < ip.csr
  Certificate Request:
      Data:
          Version: 1 (0x0)
          Subject: CN = iptest.ipa.local
          Subject Public Key Info:
              < elided >
          Attributes:
          Requested Extensions:
              X509v3 Subject Alternative Name:
                  DNS:iptest.ipa.local, IP Address:192.168.2.1
      Signature Algorithm: sha256WithRSAEncryption
           < elided >

It all looks correct.

Issuing the certificate
^^^^^^^^^^^^^^^^^^^^^^^

I use the ``ipa cert-request`` command to request a certificate.
The host ``iptest.ipa.local`` is the subject principal.  The default
profile is appropriate.

::

  % ipa cert-request ip.csr \
        --principal host/iptest.ipa.local \
        --certificate-out ip.pem
    Issuing CA: ipa
    Certificate: < elided >
    Subject: CN=iptest.ipa.local,O=IPA.LOCAL 201902181108
    Subject DNS name: iptest.ipa.local
    Issuer: CN=Certificate Authority,O=IPA.LOCAL 201902181108
    Not Before: Mon Feb 18 03:24:48 2019 UTC
    Not After: Thu Feb 18 03:24:48 2021 UTC
    Serial number: 10
    Serial number (hex): 0xA

The command succeeded.  As requested, the issued certificate has
been written to ``ip.pem``.  Again we'll use OpenSSL to inspect it::

  % openssl x509 -text < ip.pem
  Certificate:                                                                                                                                                                                               [42/694]
      Data:
          Version: 3 (0x2)
          Serial Number: 10 (0xa)
          Signature Algorithm: sha256WithRSAEncryption
          Issuer: O = IPA.LOCAL 201902181108, CN = Certificate Authority
          Validity
              Not Before: Feb 18 03:24:48 2019 GMT
              Not After : Feb 18 03:24:48 2021 GMT
          Subject: O = IPA.LOCAL 201902181108, CN = iptest.ipa.local
          Subject Public Key Info:
              Public Key Algorithm: rsaEncryption
                  RSA Public-Key: (2048 bit)
                  Modulus:
                      < elided >
                  Exponent: 65537 (0x10001)
          X509v3 extensions:
              X509v3 Authority Key Identifier:
                  keyid:70:C0:D3:02:EA:88:4A:4D:34:4C:84:CD:45:5F:64:8A:0B:59:54:71

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
                  3D:A9:7E:E3:05:D6:03:6A:9E:85:BB:72:69:E1:E7:11:92:6F:29:08
              X509v3 Subject Alternative Name:
                  DNS:iptest.ipa.local, IP Address:192.168.2.1
      Signature Algorithm: sha256WithRSAEncryption
           < elided >

We can see that the Subject Alternative Name extension is present,
and included the expected values.


Error scenarios
^^^^^^^^^^^^^^^

It's nice to see that we can get a certificate with IP address
names.  But it's more important to know that we *cannot* get an IP
address certificate when the validation requirements are not
satisfied.  I'll run through a number of scenarios and show the
results (without showing the whole procedure, which would repeat a
lot of information).

If we omit the DNS name from the SAN extension, there is nothing
linking the IP address to the subject principal and the request will
be rejected.  Note that the Subject DN Common Name (CN) attribute is
ignored for the purposes of SAN IP address validation.  The CSR was
generated using ``--extSAN ip:192.168.2.1``.

::

  % ipa cert-request ip-bad.csr --principal host/iptest.ipa.local
  ipa: ERROR: invalid 'csr': IP address in
    subjectAltName (192.168.2.1) unreachable from DNS names

If we reinstate the DNS name but add an extra IP address that does
not relate to the hostname, the request gets rejected.  The CSR was
generated using ``--extSAN
dns:iptest.ipa.local,ip:192.168.2.1,ip:192.168.2.2``.

::

  % ipa cert-request ip-bad.csr --principal host/iptest.ipa.local
  ipa: ERROR: invalid 'csr': IP address in
    subjectAltName (192.168.2.2) unreachable from DNS names


Requesting a certificate for a user principal fails.  The CSR has
Subject DN ``CN=alice`` and the SAN extension contain an IP address.
The user principal ``alice`` does exist.

::

  % ipa cert-request ip-bad.csr --principal alice
  ipa: ERROR: invalid 'csr': subject alt name type
    IPAddress is forbidden for user principals

Let's return to our original, working CSR.  If we alter the relevant
PTR record so that it no longer points a DNS name in the SAN (or the
canonical name thereof), the request will fail::

  % ipa dnsrecord-mod 2.168.192.in-addr.arpa. 1 \
        --ptr-rec f29-0.ipa.local.
    Record name: 1
    PTR record: f29-0.ipa.local.

  % ipa cert-request ip.csr --principal host/iptest.ipa.local
  ipa: ERROR: invalid 'csr': IP address in
    subjectAltName (192.168.2.1) does not match A/AAAA records

Similarly if we delete the PTR record, the request fails (with a
different message)::

  % ipa dnsrecord-del 2.168.192.in-addr.arpa. 1 \
        --ptr-rec f29-0.ipa.local.
  ------------------
  Deleted record "1"
  ------------------

  % ipa cert-request ip.csr --principal host/iptest.ipa.local
  ipa: ERROR: invalid 'csr': IP address in
    subjectAltName (192.168.2.1) does not have PTR record


IPv6
^^^^

Assuming the relevant reverse zone is managed by FreeIPA and
contains the correct records, FreeIPA can issue certificates with
IPv6 names.  First I have to add the relevant zones and records.
I'm using the machine's link-local address but the commands will be
similar for other IPv6 addresses.

::

  % ipa dnsrecord-mod ipa.local. iptest \
        --a-rec=192.168.2.1 \
        --aaaa-rec=fe80::8f18:bdab:4299:95fa
    Record name: iptest
    A record: 192.168.2.1
    AAAA record: fe80::8f18:bdab:4299:95fa

  % ipa dnszone-add \
        --name-from-ip fe80::8f18:bdab:4299:95fa
  Zone name [0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa.]:
    Zone name: 0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa.
    Active zone: TRUE
    Authoritative nameserver: f29-0.ipa.local.
    Administrator e-mail address: hostmaster
    SOA serial: 1550468242
    SOA refresh: 3600
    SOA retry: 900
    SOA expire: 1209600
    SOA minimum: 3600
    BIND update policy: grant IPA.LOCAL krb5-subdomain 0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa. PTR;
    Dynamic update: FALSE
    Allow query: any;
    Allow transfer: none;

  % ipa dnsrecord-add \
        0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa. \
        a.f.5.9.9.9.2.4.b.a.d.b.8.1.f.8 \
        --ptr-rec iptest.ipa.local.
    Record name: a.f.5.9.9.9.2.4.b.a.d.b.8.1.f.8
    PTR record: iptest.ipa.local.

With these in place I'll generate the CSR and issue the certificate.
(This time I've used the ``-f`` and ``-z`` options to reduce user
interaction.)

::

  % certutil -d . -f pwdfile.txt \
      -z <(dd if=/dev/random bs=2048 count=1 status=none) \
      -R -a -o ip.csr -s CN=iptest.ipa.local \
      --extSAN dns:iptest.ipa.local,ip:fe80::8f18:bdab:4299:95fa


  Generating key.  This may take a few moments...

  % ipa cert-request ip.csr \
        --principal host/iptest.ipa.local \
        --certificate-out ip.pem
    Issuing CA: ipa
    Certificate: < elided >
    Subject: CN=iptest.ipa.local,O=IPA.LOCAL 201902181108
    Subject DNS name: iptest.ipa.local
    Issuer: CN=Certificate Authority,O=IPA.LOCAL 201902181108
    Not Before: Mon Feb 18 05:49:01 2019 UTC
    Not After: Thu Feb 18 05:49:01 2021 UTC
    Serial number: 12
    Serial number (hex): 0xC

The issuance succeeded.  Observe that the IPv6 address is present in
the certificate::

  % openssl x509 -text < ip.pem | grep -A 1 "Subject Alt"
      X509v3 Subject Alternative Name:
        DNS:iptest.ipa.local, IP Address:FE80:0:0:0:8F18:BDAB:4299:95FA

Of course, it is possible to issue certificates with multiple IP
addresses, including a mix of IPv4 and IPv6.  Assuming all the
necessary DNS records exist, with

::

  --extSAN ip:fe80::8f18:bdab:4299:95fa,ip:192.168.2.1,dns:iptest.ipa.local

The resulting certificate will have the SAN::

  IP Address:FE80:0:0:0:8F18:BDAB:4299:95FA, IP Address:192.168.2.1, DNS:iptest.ipa.local


Conclusion
----------

In this post I discussed the challenges of verifying IP addresses
for inclusion in X.509 certificates.  I discussed the approach we
are taking in FreeIPA to finally support this, including its caveats
and limitations.  For comparison, I outlined how IP address
verification is done by CAs on the open internet.

I then demonstrated how the feature will work in FreeIPA.
Importantly, I showed (though not *exhaustively*), that FreeIPA
refuses to issue the certificate if the verification requirements
are not met.  It is a bit hard to demonstrate, from a user
perspective, that we only consult FreeIPA's own DNS records and
never consult another DNS server.  But hey, `the code is open
source`_ so you can satisfy yourself that the behaviour fulfils the
requirements (or leave a review / file an issue if you find that it
does not!)

.. _the code is open source: https://github.com/freeipa/freeipa/pull/1843

When will the feature land in ``master``?  Before the feature can be
merged, I still need to write acceptance tests and have the feature
reviewed by another FreeIPA developer.  I am hoping to finish the
work this week.

As a final remark, I must again acknowledge Ian Pilcher's
significant contribution.  Were it not for him, it is likely that
this longstanding RFE would still be in our *"too hard"* basket.
Ian, thank you for your patience and I hope that your efforts are
rewarded very soon with the feature finally being merged.

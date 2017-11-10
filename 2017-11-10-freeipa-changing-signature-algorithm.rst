Changing the X.509 signature algorithm in FreeIPA
=================================================

X.509 certificates are an application of *digital signatures* for
identity verification.  TLS uses X.509 to create a *chain of trust*
from a trusted CA to a service certificate.  An X.509 certificate
binds a public key to a *subject* by way of a secure and verifiable
*signature* made by a *certificate authority (CA)*.

A signature algorithm has two parts: a public key signing algorithm
(determined by the type of the CA's signing key) and a
*collision-resistant* hash function.  The hash function *digests*
the certified data into a small value that is hard to find collision
for, which gets signed.

Computers keep getting faster and attacks on cryptography always get
better.  So over time older algorithms need to be deprecated, and
newer algorithms adopted for use with X.509.  In the past the MD5
and SHA-1 digests were often used with X.509, but today SHA-256 (a
variant of SHA-2) is the most used algorithm.  SHA-256 is also the
weakest digest accepted by many programs (e.g. web browsers).
Stronger variants of SHA-2 are widely supported.

FreeIPA currently uses the ``sha256WithRSAEncryption`` signature
algorithm by default.  Sometimes we get asked about how to use a
stronger digest algorithm.  In this article I'll explain how to do
that and discuss the motivations and implications.


Implications of changing the digest algorithm
---------------------------------------------

Unlike re-keying or changing the CA's Subject DN, re-issuing a
certificate signed by the same key, but using a different digest,
should Just Work.  As long as a client knows about the digest
algorithm used, it will be able to verify the signature.  It's fine
to have a chain of trust that uses a variety of signature
algorithms.


Configuring the signature algorithm in FreeIPA
----------------------------------------------

The signature algorithm is configured in each Dogtag certificate
profile.  Different profiles can use different signature algorithms.
The public key signing algorithm depends on the CA's key type (e.g.
RSA) so you can't change it; you can only change the digest used.

Modifying certificate profiles
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Before FreeIPA 4.2 (RHEL 7.2), Dogtag stored certificate profile
configurations as flat files.  Dogtag 9 stores them in
``/var/lib/pki-ca/profiles/ca`` and Dogtag >= 10 stores them in
``/var/lib/pki/pki-tomcat/ca/profiles/ca``.  When Dogtag is using
file-based profile storage you must modify profiles on all CA
replicas for consistent behaviour.  After modifying a profile,
Dogtag requires a restart to pick up the changes.

As of FreeIPA 4.2, Dogtag uses LDAP-based profile storage.  Changes
to profiles get replicated among the CA replicas, so you only need
to make the change once.  Restart is not required.  The ``ipa
certprofile`` plugin provides commands for importing, exporting and
modifying certificate profiles.

Because of the variation among versions, I won't detail the process
of modifying profiles.  We'll look at what modifications to make,
but skip over how to apply them.

Profile configuration changes
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

For service certificates, the profile to modify is
``caIPAserviceCert``.  If you want to renew the CA signing cert with
a different algorithm, modify the ``caCACert`` profile.  The
relevant profile policy components are ``signingAlgConstraintImpl``
and ``signingAlgDefaultImpl``.  Look for these components in the
profile configuration::

  policyset.serverCertSet.8.constraint.class_id=signingAlgConstraintImpl
  policyset.serverCertSet.8.constraint.name=No Constraint
  policyset.serverCertSet.8.constraint.params.signingAlgsAllowed=SHA1withRSA,SHA256withRSA,SHA512withRSA,MD5withRSA,MD2withRSA,SHA1withDSA,SHA1withEC,SHA256withEC,SHA384withEC,SHA512withEC
  policyset.serverCertSet.8.default.class_id=signingAlgDefaultImpl
  policyset.serverCertSet.8.default.name=Signing Alg
  policyset.serverCertSet.8.default.params.signingAlg=-

Update the ``policyset.<name>.<n>.default.params.signingAlg``
parameter; replace the ``-`` with the desired signing algorithm.  (I
set it to ``SHA512withRSA``.)  Ensure that the algorithm appears in
the ``policyset.<name>.<n>.constraint.params.signingAlgsAllowed``
parameter (if not, add it).

After applying this change, certificates issued using the modified
profile will use the specified algorithm.

Results
-------

After modifying the ``caIPAserviceCert`` profile, we can renew the
HTTP certificate and see that the new certificate uses
``SHA512withRSA``.  Use ``getcert list`` to find the Certmonger
tracking request ID for this certificate.  We find the tracking
request in the output::

  ...
  Request ID '20171109075803':
    status: MONITORING
    stuck: no
    key pair storage: type=NSSDB,location='/etc/httpd/alias',nickname='Server-Cert',token='NSS Certificate DB',pinfile='/etc/httpd/alias/pwdfile.txt'
    certificate: type=NSSDB,location='/etc/httpd/alias',nickname='Server-Cert',token='NSS Certificate DB'
    CA: IPA
    issuer: CN=Certificate Authority,O=IPA.LOCAL
    subject: CN=rhel69-0.ipa.local,O=IPA.LOCAL
    expires: 2019-11-10 07:53:11 UTC
    ...
  ...

So the tracking request ID is ``20171109075803``.  Now resubmit the
request::

  [root@rhel69-0 ca]# getcert resubmit -i 20171109075803
  Resubmitting "20171109075803" to "IPA".

After a few moments, check the status of the request::

  [root@rhel69-0 ca]# getcert list -i 20171109075803
  Number of certificates and requests being tracked: 8.
  Request ID '20171109075803':
    status: MONITORING
    stuck: no
    key pair storage: type=NSSDB,location='/etc/httpd/alias',nickname='Server-Cert',token='NSS Certificate DB',pinfile='/etc/httpd/alias/pwdfile.txt'
    certificate: type=NSSDB,location='/etc/httpd/alias',nickname='Server-Cert',token='NSS Certificate DB'
    CA: IPA
    issuer: CN=Certificate Authority,O=IPA.LOCAL
    subject: CN=rhel69-0.ipa.local,O=IPA.LOCAL
    expires: 2019-11-11 00:02:56 UTC
    ...

We can see by the ``expires`` field that renewal succeeded.
Pretty-printing the certificate shows that it is using the new
signature algorithm::

  [root@rhel69-0 ca]# certutil -d /etc/httpd/alias -L -n 'Server-Cert'
  Certificate:
      Data:
          Version: 3 (0x2)
          Serial Number: 12 (0xc)
          Signature Algorithm: PKCS #1 SHA-512 With RSA Encryption
          Issuer: "CN=Certificate Authority,O=IPA.LOCAL"
          Validity:
              Not Before: Fri Nov 10 00:02:56 2017
              Not After : Mon Nov 11 00:02:56 2019
          Subject: "CN=rhel69-0.ipa.local,O=IPA.LOCAL"

It is using SHA-512/RSA.  Mission accomplished.


Discussion
----------

In this article I showed how to configure the signing algorithm in a
Dogtag certificate profile.  Details about how to modify profiles in
particular versions of FreeIPA was out of scope.

In the example I modified the default service certificate profile
``caIPAserviceCert`` to use ``SHA512withRSA``.  Then I renewed the
HTTP TLS certificate to confirm that the configuration change had
the intended effect.  To change the signature algorithm on the
FreeIPA CA certificate, you would modify the ``caCACert`` profile
then renew the CA certificate.  This would only work if the FreeIPA
CA is *self-signed*.  If it is externally-signed, it is up to the
external CA what digest to use.

In FreeIPA version 4.2 and later, we support the addition of custom
certificate profiles.  If you want to use a different signature
algorithm for a specific use case, instead of modifying the default
profile (``caIPAserviceCert``) you might add a new profile.

The default signature digest algorithm in Dogtag is currently
SHA-256.  This is appropriate for the present time.  There are few
reasons why you would need to use something else.  Usually it is
because of an arbitrary security decision imposed on FreeIPA
administrators.  There are currently no plans to make the default
signature algorithm configurable.  But you can control the signature
algorithm for a self-signed FreeIPA CA certificate via the
``ipa-server-install`` ``--ca-signing-algorithm`` option.

In the introduction I mentioned that the CA's key type determines
the public key signature algorithm.  That was hand-waving; some key
types support multiple signature algorithms.  For example, RSA keys
support two signature algorithms: *PKCS #1 v1.5* and *RSASSA-PSS*.
The latter is seldom used in practice.

The SHA-2 family of algorithms (SHA-256, SHA-384 and SHA-512) are
the "most modern" digest algorithms standardised for use in X.509
(`RFC 4055`_).  The Russian *GOST R* digest and signature algorithms
are also supported (`RFC 4491`_) although support is not widespread.
In 2015 NIST published SHA-3 (based on the *Keccak* sponge
construction).  The use of SHA-3 in X.509 has not yet been
standardised.  There was an `Internet-Draft in 2017`_, but it
expired.  The current cryptanalysis of SHA-2 suggests there is no
urgency to move to SHA-3.  But it took a long time to move from
SHA-1 (which is now insecure for applications requiring collision
resistance) to SHA-2.  Therefore it would be good to begin efforts
to standardise SHA-3 in X.509 and add library/client support as soon
as possible.

.. _RFC 4055: https://tools.ietf.org/html/rfc4055#section-2.1
.. _RFC 4491: https://tools.ietf.org/html/rfc4491
.. _Internet-Draft in 2017: https://tools.ietf.org/html/draft-turner-lamps-adding-sha3-to-pkix-01

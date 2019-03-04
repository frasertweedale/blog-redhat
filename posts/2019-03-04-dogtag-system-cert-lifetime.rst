---
tags: dogtag, profiles, howto
---

Customising Dogtag system certificate lifetimes
===============================================

Default certificate lifetimes in Dogtag are 20 years for the CA
certificate (when self-signed) and about 2 years for other system
certificates.  These defaults also apply to FreeIPA.  It can be
desirable to have shorter certificate lifetimes.  And although I
wouldn't recommend to use *longer* lifetimes, people sometimes want
that.

There is no *supported* mechanism for customising system certificate
validity duration during Dogtag or FreeIPA installation.  But it can
be done.  In this post I'll explain how.


Profile configuration files
---------------------------

During installation, profile configurations are copied from the RPM
install locations under ``/usr/share`` to the new Dogtag instance's
configuration directory.  If the LDAP profile subsystem is used
(FreeIPA uses it) they are further copied from the instance
configuration directory into the LDAP database.

There is no facility or opportunity to modify the profiles during
installation.  So if you want to customise the certificate
lifetimes, you have to modify the files under ``/usr/share``.

There are two directories that contain profile configurations:

``/usr/share/pki/ca/profiles/ca/*.cfg``
  These profile configurations are available during general
  operation.

``/usr/share/pki/ca/conf/*.profile``
  These *overlay* configurations used during installation when
  issuing system certificates.  Each configuration references an
  underlying profile and can override or extend the configuration.

``/usr/share/ipa/profiles/*.cfg``
  Profiles that are shipped by FreeIPA and imported into Dogtag are
  defined here.  The configurations for the LDAP, Apache HTTPS and
  KDC certificates are found here.

I'll explain which configuration file is used for which certificate
later on in this post.


Specifying the validity period
------------------------------

The configuration field for setting the validity period are::

  <component>.default.params.range=720
  <component>.constraint.params.range=720

where ``<component>`` is some key, usually a numeric index, that may
be different for different profiles.  The actual profile component
classes are ``ValidityDefault`` and ``ValidityConstraint``, or
``{CA,User}Validity{Default,Constraint}`` for some profiles.

The ``default`` component sets the default validity period for this
profile, whereas the constraint sets the *maximum* duration in case
the user overrides it.  Note that if an override configuration
overrides the ``default`` value such that it exceeds the
``constraint`` specified in the underlying configuration, issuance
will fail due to constraint violation.  It is usually best to
specify both the ``default`` and ``constraint`` together, with the
same value.

The default range unit is ``day``, so the configuration above means
*720 days*.  Use the ``rangeUnit`` parameter to specify a different
unit.  The supported units are ``year``, ``month``, ``day``,
``hour`` and ``minute``.  For example::

  <component>.default.params.range=3
  <component>.default.params.rangeUnit=month
  <component>.constraint.params.range=3
  <component>.constraint.params.rangeUnit=month


Which configuration for which certificate?
------------------------------------------

CA certificate (when self-signed)
  ``/usr/share/pki/ca/conf/caCert.profile``

OCSP signing certificate
  ``/usr/share/pki/ca/conf/caOCSPCert.profile``

Subsystem certificate
  ``/usr/share/pki/ca/conf/rsaSubsystemCert.profile`` when using
  RSA keys (the default)

Dogtag HTTPS certificate
  ``/usr/share/pki/ca/conf/rsaServerCert.profile`` when using
  RSA keys (the default)

Audit signing
  ``/usr/share/pki/ca/conf/caAuditSigningCert.profile``

IPA RA agent (FreeIPA-specific)
  ``/usr/share/pki/ca/profiles/ca/caServerCert.cfg``

Apache and LDAP certificates (FreeIPA-specific)
  ``/usr/share/ipa/profiles/caIPAserviceCert.cfg``

KDC certificate (FreeIPA-specific)
  ``/usr/share/ipa/profiles/KDCs_PKINIT_Certs.cfg``


Testing
-------

I made changes to the files mentioned above, so that certificates
would be issued with the following validity periods:

========= =========
CA        5 years
OCSP      1 year
Subsystem 6 months
HTTPS     3 months
Audit     1 year
IPA RA    15 months
Apache    4 months
LDAP      4 months
KDC       18 months
========= =========

I installed FreeIPA (with a self-signed CA).  After installation
completed, I had a look at the certificates that were being tracked
by Certmonger.  For reference, the installation took place on March
4, 2019 (**2019-03-04**).

::

  # getcert list |egrep '^Request|certificate:|expires:'
  Request ID '20190304044028':
    certificate: type=FILE,location='/var/lib/ipa/ra-agent.pem'
    expires: 2020-06-04 15:40:30 AEST
  Request ID '20190304044116':
    certificate: type=NSSDB,location='/etc/pki/pki-tomcat/alias',nickname='auditSigningCert cert-pki-ca',token='NSS Certificate DB'
    expires: 2020-03-04 15:39:53 AEDT
  Request ID '20190304044117':
    certificate: type=NSSDB,location='/etc/pki/pki-tomcat/alias',nickname='ocspSigningCert cert-pki-ca',token='NSS Certificate DB'
    expires: 2020-03-04 15:39:53 AEDT
  Request ID '20190304044118':
    certificate: type=NSSDB,location='/etc/pki/pki-tomcat/alias',nickname='subsystemCert cert-pki-ca',token='NSS Certificate DB'
    expires: 2019-09-04 15:39:53 AEST
  Request ID '20190304044119':
    certificate: type=NSSDB,location='/etc/pki/pki-tomcat/alias',nickname='caSigningCert cert-pki-ca',token='NSS Certificate DB'
    expires: 2024-03-04 15:39:51 AEDT
  Request ID '20190304044120':
    certificate: type=NSSDB,location='/etc/pki/pki-tomcat/alias',nickname='Server-Cert cert-pki-ca',token='NSS Certificate DB'
    expires: 2019-06-04 15:39:53 AEST
  Request ID '20190304044151':
    certificate: type=NSSDB,location='/etc/dirsrv/slapd-IPA-LOCAL',nickname='Server-Cert',token='NSS Certificate DB'
    expires: 2019-07-04 15:41:52 AEST
  Request ID '20190304044225':
    certificate: type=FILE,location='/var/lib/ipa/certs/httpd.crt'
    expires: 2019-07-04 15:42:26 AEST
  Request ID '20190304044234':
    certificate: type=FILE,location='/var/kerberos/krb5kdc/kdc.crt'
    expires: 2020-09-04 15:42:34 AEST

Observe that the certificate have the intended periods.


Discussion
----------

The procedure outlined in this post is not officially supported, and
not recommended.  But the desire to choose different validity
periods is sometimes justified, especially for the CA certificate.
So should FreeIPA allow customisation of the system certificate
validity periods?  To what extent?

We need to reduce the default CA validity from 20 years, given the
2048-bit key size.  (There is a separate issue to support generating
a larger CA signing key, too).  Whether the CA validity period
should be configurable is another question.  My personal opinion is
that it makes sense to allow the customer to choose the CA lifetime.

For system certificates, I think that customers should just accept
the defaults.  PKI systems are trending to shorter lifetimes for
end-entity certificates, which is a good thing.  For FreeIPA,
unfortunately we are still dealing with a lot of certificate renewal
issues that arise from the complex architecture.  Until we are
confident in the robustness of the renewal system, and have observed
a reduction in customer issues, it would be a mistake to
substantially reduce the validity period for system certificates.
Likewise, it is not yet a good idea to let customers choose the
certificate validity periods.

On the other hand, the team is considering changing the default
validity period of system certificates *a little bit*, so that
different certificates are on different renewal candences.  This
would simplify recovery in some scenarios: it is easier to recover
when only *some* of the certificates expired, instead of *all* of
them at once.

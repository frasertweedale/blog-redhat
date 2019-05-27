---
tags: freeipa, certificates, integration
---

X.509 Name Constraints and FreeIPA
==================================

The X.509 *Name Constraints* extension is a mechanism for
constraining the name space(s) in which a *certificate authority
(CA)* may (or may not) issue *end-entity* certificates.  For
example, a CA could issue to *Bob's Widgets, Inc* a contrained CA
certificate that only allows the CA to issue server certificates for
``bobswidgets.com``, or subdomains thereof.  In a similar way, an
enterprise root CA could issue constrained certificates to different
departments in a company.

What is the advantage?  Efficiency can be improved without
sacrificing security by enabling *scoped* delegation of certificate
issuance capability to subordinate CAs controlled by different
organisations.  The name constraints extension is essential for the
security of such a mechanism.  The *Bob's Widgets, Inc* CA must not
be allowed to issue valid certificates for ``google.com`` (and vice
versa!)

FreeIPA supports installation with an externally signed CA.  It is
possible that such a CA certificate could have a name constraints
extension, defined and imposed by the external issuer.  Does FreeIPA
support this?  What are the caveats?  In this blog post I will
describe in detail how Name Constraints work and the state of
FreeIPA support.  Along the way I will dive into the state of Name
Constraints verfication in the NSS security library.  And I will
conclude with a discussion of limitations, alternatives and
complementary controls.


Name Constraints
----------------

The Name Constraints extension is `defined in RFC 5280`_.  Just as
the *Subject Alternative Name (SAN)* is a list of ``GeneralName``
values with various possible types (DNS name, IP address, DN, etc),
the Name Constraints extension also contains a list of
``GeneralName`` values.  The difference is in interpretation.  In
the Name Constraints extension:

- A DNS name means that the CA may issue certificates with DNS names
  in the given domain, or a subdomain of arbitrary depth.

- An IP address is interpreted as a CIDR address range.

- A directory name is interpreted as a base DN.

- An RFC822 name can be a single mailbox, all mailboxes at a
  particular host, or all mailboxes at a particular domain
  (including subdomains).

- The ``SRVName`` name type, and corresponding Name Constraints
  matching rules, are defined in `RFC 4985`_.

There are other rules for other name types, but I won't elaborate
them here.

In X.509 terminology, these name spaces are called *subtrees*.  The
Name Constraints extension can define *permitted subtrees* and/or
*excluded subtrees*.  Permitted subtrees is more often used because
it defines what is allowed, and anything not explicitly allowed is
prohibited.  It is possible for a single Name Constraints extension
to define both permitted and excluded subtrees.  But I have never
seen this in the wild, and I will not bother explaining the rules.

When validating a certificate, the Name Constraints subtrees of all
CA certificates in the certification path are merged, and the
certificate is checked against the merged results.  Name values in
the SAN extension are compared to Name Constraint subtrees of the
same type (the comparison rules differ for each name type.)

In addition to comparing SAN names against Name Constraints, there
are a couple of additional requirements:

- ``directoryName`` constraints are checked against the whole Subject
  DN, in additional to ``directoryName`` SAN values.

- ``rfc822Name`` constraints are checked against the
  ``emailAddress`` Subject DN attribute (if present) in addition to
  ``rfc822Name`` SAN values.  (Use of the ``emailAddress`` attribute
  is deprecated in favour of ``rfc822Name`` SAN values.)

Beyond this, because of the legacy *de facto* use of the Subject DN
CN attribute to carry DNS names, several implementations check the
CN attribute against ``dnsName`` constraints.  This behaviour is not
defined (let alone required) by RFC 5280.  It is reasonable
behaviour when dealing with server certificates.  But we will see
that this behaviour can lead to problems in other scenarios.

.. _defined in RFC 5280: https://tools.ietf.org/html/rfc5280#section-4.2.1.10


It is important to mention that nothing prevents a constrained CA
from issuing a certificate that violates its Name Constraints
(either direct or transitive).  Validation must be performed by a
client.  If a client does not validate Name Constraints, then even a
(trusted) issuing CA with a ``permittedSubtrees`` ``dnsName``
constraint of ``bobswidgets.com`` could issue a certificate for
``google.com`` and the client will accept it.  Fortunately, modern
web browsers strictly enforce DNS name constraints.  For other
clients, or other name types, Name Constraint enforcement support is
less consistent.  I haven't done a thorough survey yet but you
should make your own investigations into the state of Name
Constraint validation support in libraries or programs relevant to
your use case.


FreeIPA support for constrained CA certificates
-----------------------------------------------

It is common to deploy FreeIPA with a subordinate CA certificate
signed by an external CA (e.g. the organisation's Active Directory
CA).  If the FreeIPA deployment controls the ``ipa.bobswidgets.com``
subdomain, then it is reasonable for the CA administrator to issue
the FreeIPA CA certificate with a Name Constraints
``permittedSubtree`` of ``ipa.bobswidgets.com``.  Will this work?

The most important thing to consider is that all names in all
certificates issued by the FreeIPA CA must conform to whatever Name
Constraints are imposed by the external CA.  Above all else, the
constraints must permit all DNS names used by the IPA servers across
the whole topology.  Support for DNS name constraint enforcement is
widespread, so if this condition is not met, nothing with work.
Most likely not even installation with succeed.  So if the permitted
``dnsName`` constraint is ``ipa.bobswidgets.com``, then every server
hostname must be in that subtree.  Likewise for SRV names, RFC822
names and so on.

In a typical deployment scenario this is not a burdensome
requirement.  And if the requirements change (e.g. needing to add a
FreeIPA replica with a hostname excluded by Name Constraints) then
the CA certificate could be re-issued with an updated Name
Constraints extension to allow it.  In some use cases (e.g. FreeIPA
issuing certificates for cloud services), Name Constraints in the CA
certificate may be untenable.

If the external issuer imposes a ``directoryName`` constraint, more
care must be taken, because as mentioned above, these constraints
apply to the Subject DN of issued certificates.  The deployment's
*subject base* (an installation parameter that defines the base
subject DN used in all default certificate profiles) must correspond
to the ``directoryName`` constraint.  Also, the Subject DN
configuration for custom certificate profiles must correspond to the
constraint.

If all of these conditions are met, then there should be no problem
having a constrained FreeIPA CA.


A wild Name Constraint validation bug appears!
----------------------------------------------

You didn't think the story would end there, did you?  As is often
the case, my study of some less commonly used feature of X.509 was
inspired by a customer issue.  The customer's external CA issued a
CA certificate with ``dnsName`` and ``directoryName`` constraints.
The ``permittedSubtree`` values were reasonable.  Everything looked
fine, but nothing worked (not even installation).  Dogtag would not
start up, and the debug log showed that the startup self-test was
complaining about the OCSP signing certificate::

  The Certifying Authority for this certificate is not
  permitted to issue a certificate with this name.

Adding to the mystery, when the ``certutil(1)`` program was used to
validate the certificate, the result was success::

  # certutil -V -e -u O \
    -d /etc/pki/pki-tomcat/alias \
    -f /etc/pki/pki-tomcat/alias/pwdfile.txt \
    -n "ocspSigningCert cert-pki-ca"
  certutil: certificate is valid

Furthermore, the customer was experiencing (and I was also able to
reproduce) the issue on RHEL 7, but I could not reproduce the issue
on recent versions of Fedora or the RHEL 8 beta.

``directoryName`` constraints are uncommon (relative to ``dnsName``
constraints).  And having in my past encountered many issues caused
by DN string encoding mismatches (a valid scenario, but some
libraries do not handle it correctly), my initial theory was that
this was the cause.  Dogtag uses the NSS security library (via the
JSS binding for Java), and a search of the NSS commit log uncovered
an interesting change that supported my theory::

  Author: David Keeler <dkeeler@mozilla.com>
  Date:   Wed Apr 8 16:17:39 2015 -0700

    bug 1150114 - allow PrintableString to match UTF8String
                  in name constraints checking r=briansmith

On closer examination however, this change affected code in the
*mozpkix* library (part of NSS), which is not invoked by the
certificate validation routines used by Dogtag and ``certutil``
program.  But if the *mozpkix* Name Constraint validation code was
not being used, where was the relevant code?

Finding the source of the problem
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Some more reading of NSS code showed that the error originated in
*libpkix* (also part of NSS).

To work out why ``certutil`` was succeeding where Dogtag was
failing, I launched ``certutil`` in a debugger to see what was going
on.  Eventually I reached the following routine::

  SECStatus
  cert_VerifyCertChain(CERTCertDBHandle *handle, CERTCertificate *cert,
                       PRBool checkSig, PRBool *sigerror,
                       SECCertUsage certUsage, PRTime t, void *wincx,
                       CERTVerifyLog *log, PRBool *revoked)
  {
    if (CERT_GetUsePKIXForValidation()) {
      return cert_VerifyCertChainPkix(cert, checkSig, certUsage, t,
                                      wincx, log, sigerror, revoked);
    }
    return cert_VerifyCertChainOld(handle, cert, checkSig, sigerror,
  }

OK, now I was getting somewhere.  It turns out that during library
initialisation, NSS reads the ``NSS_ENABLE_PKIX_VERIFY`` environment
variable and sets a global variable, the value of which determines
the return value of ``CERT_GetUsePKIXForValidation()``.  The
behaviour can also be controlled explicitly via
``CERT_SetUsePKIXForValidation(PRBool enable)``.

When invoking ``certutil`` ourselves, this environment variable was
not set so the "old" validation subroutine was invoked.  Both routines
perform cryptographic validation of a certification path to a
trusted CA, and several other important checks.  But
the *libpkix* routine is more thorough, performing Name Constraints
checks, in addition to OCSP and perhaps other checks that are not also
performed by the "old" subroutine.

If an environment variable or explicit library call is required to
enable *libpkix* validation, why was the error occuring in Dogtag?
The answer is simple: as part of ``ipa-server-install``, we update
``/etc/sysconfig/pki-tomcat`` to set ``NSS_ENABLE_PKIX_VERIFY=1`` in
Dogtag's process environment.  This was implemented a few years ago
to support OCSP validation of server certificates in connections
made by Dogtag (e.g. to the LDAP server).

The bug
^^^^^^^

Stepping through the code revealed the true nature of the bug.
*libpkix* Name Constraints validation treats the Common Name (CN)
attribute of the Subject DN as a DNS name for the purposes of name
constraints validation.  I already mentioned that this is reasonable
behaviour for server certificates.  But *libpkix* has this behaviour
for *all end-entity certiticates*.  For an OCSP signing certificate,
whose CN attribute carries no special meaning (formally or
conventionally), this behaviour is wrong.  And it is the bug at the
root of this problem.  I filed a `bug in the Mozilla tracker
<https://bugzilla.mozilla.org/show_bug.cgi?id=1523484>`_ along with
a patch—my attempt at fixing the issue.  Hopefully a fix can be
merged soon.

Why no failure on newer releases?
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The issue does not occur on Fedora >= 28 (or maybe earlier, but I
haven't tested), nor the RHEL 8 beta.  So was there already a fix
for the issue in NSS, or did something change in Dogtag, FreeIPA or
elsewhere?

In fact, the change was in Dogtag.  In recent versions we switched
to a less comprehensive certificate validation routine—one that does
not use *libpkix*.  This is just the default behaviour; the old
behaviour can still be enabled.  We made this change because in some
scenarios the OCSP checking performed by *libpkix* causes Dogtag
startup to hang.  Because the OCSP server it is trying to reach to
validate certificates during start self-test *is the same Dogtag
instance that is starting up!*  Because of the change to the
self-test validation behaviour, FreeIPA deployments on Fedora >= 28
and RHEL 8 beta do not experience this issue.

Workaround?
^^^^^^^^^^^

If you were experiencing this issue in an existing release (e.g.
because you *renewed* the CA certificate on your *existing* FreeIPA
deployment, and the Name Constraints *appeared on the new
certificate*), an obvious workaround would be to remove the
environment variable from ``/etc/sysconfig/pki-tomcat``.  That would
work, and the change will persist even after an
``ipa-server-upgrade``.  But that assumes you already had a working
installation.  Which the customer doesn't have, becaues installation
itself is failing.  So apart from modifying the FreeIPA code to
avoid setting this environment variable in the first place, I don't
yet know of a reliable workaround.

This concludes the discussion of constrained CA certificate support
in FreeIPA.


Limitiations, alternatives and related topics
---------------------------------------------

Name Constraints only constrains names.  There are other ways you
might want to constrain a CA.  For example: *can only issue
certificates with validity period <= δ*, or *can only issue
certificates with Extended Key Usages ∈ S*.  But there are no
mechanisms for constraining CAs in these ways.

Not all defined ``GeneralName`` types have Name Constraints syntax
and semantics defined for them.  Documents that define ``otherName``
types *may* define corresponding Name Constraints matching rules,
but are not required to.  For example `RFC 4985`_, which defines the
``SRVName`` type, also defines Name Constraints rules for it.  But
`RFC 4556`_, which specifies the Kerberos PKINIT protocol, defines
the ``KRB5PrincipalName`` ``otherName`` type but no Name Constraints
semantics.

.. _RFC 4985: https://tools.ietf.org/html/rfc4985#section-4
.. _RFC 4556: https://tools.ietf.org/html/rfc4556

For applications where the set of domains (or other names) is
volatile, a constrained CA certificate is likely to be more of a
problem than a solution.  An example might be a cloud or
Platform-as-a-Service provider wanting to issue certificates on
behalf of customers, who bring their own domains.  For this use case
it would be better to use an existing CA that supports automated
domain validation and issuance, such as `Let's Encrypt
<https://letsencrypt.org/>`_.

Name Constraints say which names a CA is or is not allowed to issue
certificates for.  But this restriction is controlled by the
superior CA(s), not the end-entity.  Interestingly there is a way
for a domain owner to indicate which CAs are authorised to issue
certificates for names in the domain.  The DNS `CAA record (RFC
6844) <https://tools.ietf.org/html/rfc6844>`_ can anoint one more
CAs, implicitly prohibiting other CAs from issuing certificates for
that domain.  The CA itself can check for these records, as a
control against mis-issuance.  For publicly-trusted CAs, the
CA-Browser Forum *Baseline Requirements* **requires** CAs to check
and obey CAA records.  DNSSEC is recommended but not required.

CAA is an *authorisation* control—relying parties do not consult or
care about CAA records when verifying certificates.  The
verification counterpart of CAA is *DANE—DNS-based Authentication of
Named Entities*, defined in `RFC 6698
<https://tools.ietf.org/html/rfc6698>`_.  Like CAA, DANE uses DNS
(the *TLSA* record type), but DNSSEC is required.  TLSA records can
be used to indicate the authorised CA(s) for a certificate. Or they
can specify the exact certificate(s) for the domain, a kind of
*certificate pinning*.  So DANE can work hand-in-hand with the
existing public PKI infrastructure, or it can do an end-run around
it.  Depending on who you talk to, the reliance on DNSSEC makes it a
non-starter, or humanity's last hope!  In any case, support is not
yet widespread.  Today DANE can be used in some browsers via
add-ons, and the OpenSSL and GnuTLS libraries have some support.

Nowadays all publicly-trusted CAs, and some private PKIs, log all
issued certificates to *Certificate Transparency (CT)* logs.  These
logs are auditable (publicly if the log is public),
cryptographically verifiable logs of CA activity.  CT was imposed
after the detection of many serious misissuances by several
publicly-trusted CAs (most of whom are no longer trusted by anyone).
Now, even failure to log a certificate to a CT log is reason enough
to revoke trust (because *what else* might they have failed to log?
Certificates for ``google.com`` or ``yourbank.ch``?)  What does CT
have to do with Name Constraints?  When you consider that client
Name Constraints validation support is patchy at best, a CT-based
logging and audit solution is a credible alternative to Name
Constraints, or at least a valuable complementary control.


Conclusion
----------

So, we have looked at what the Name Constraints extension does, and
why it can be useful.  We have discussed its limitations and some
alternative or related mechanisms.  We looked at the state of
FreeIPA support, and did a deep dive into NSS to investigate the one
bug that seems to be getting in the way.

Name Constraints is one of the many complex features that makes
X.509 both so versatile yet so painful to work with.  It's a
necessary feature, but support is not consistent and where it
exists, there are usually bugs.  Although I did discuss some
"alternatives", a big reason you might look for an alternative is
because the support is not great in the first place.  In my opinion,
the best way forward is to ensure Name Constraints validation is
performed more often, and more correctly, while (separately)
preparing the way for comprehensive CT logging in enterprise CAs.  A
combination of monitoring (CT) and validation controls (browsers
correctly validating names, Name Constraints and requiring evidence
of CT logging) seems to be improving security in the public PKI.  If
we fix the client libraries and make CT logging and monitoring easy,
it could work well for enterprise PKIs too.

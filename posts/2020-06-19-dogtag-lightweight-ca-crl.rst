---
tags: dogtag, certificates, revocation
---

CRLs for Dogtag Lightweight CAs
===============================

A few years ago I implemented *lightweight CAs* in Dogtag.  This
feature allows multiple CAs to be hosted in a single Dogtag server
instance.  For now these are restricted to sub-CAs of the *main CA*
but this is not a fundamental restriction.

An important aspect of CA operation is *revocation*: the ability to
revoke a certificate because of (suspected) key compromise,
cessation of operation, it was superseded, etc.  There are currently
two main ways of conveying revocation status to clients:
*Certificate Revocation Lists (CRLs)* and *Online Certificate Status
Protocol (OCSP)*.  CRLs and OCSP have their respective advantages
and drawbacks.  Suffice to say, for many security-conscious
organisations CRLs are important (as is OCSP).

There is currently no support for lightweight CA certificates in
CRLs produced by Dogtag.  The purpose of this post is to discuss the
challenges and possible approaches to closing this gap.

Overview of OCSP and CRLs
-------------------------

OCSP (defined in `RFC 6960`_) is a network protocol for determining
certificate revocation status.  Any relying party (e.g.  a web
browser validating a server certificate) can ask the CA's *OCSP
responder* for a signed assertion of whether or not the certificate
is revoked.  For scalability and performance reasons, TLS servers
can periodically obtain OCSP responses for their certificate and
convey them to clients in the TLS handshake; this feature is called
`OCSP stapling`_.

.. _RFC 6960: https://tools.ietf.org/html/rfc6960
.. _OCSP stapling: https://en.wikipedia.org/wiki/OCSP_stapling

On the other hand, CRLs are a more *passive* technology.  X.509 CRLs
are defined alongside X.509 certificates in `RFC 5280`_.  In the
simple case a CRL is a signed, timestamped list of all revoked,
non-exired certificates issued by a CA.  The CA produces new CRLs on
a fixed schedule (e.g. every 4 hours) and publishes them (e.g. on
HTTP, in an LDAP directory, etc).  Clients *somehow* obtain and
refresh their CRL cache, and consult it when validating
certificates.  The CRL grows linearly in the number of revoked
certificates so on a busy CA the CRL can become *huge*.  Retrieving
a large CRL takes time and bandwidth, storing it takes space, and
consulting it takes time.  The advantage is that validation requires
no (additional) network traffic.  The assumption is that the clients
CRL cache is up to date.

.. _RFC 5280: https://tools.ietf.org/html/rfc5280

One further downside of CRLs is that they are only as good as their
most recent update.  What if your CRL is 3 hours old, the
certificate of interest was revoked 1 hour ago, and it is still 1
hour until the next CRL gets published?  In practice, every approach
to revocation suffers from such a delay.  Also in practice, the
delay duration is often much greater for CRLs than for OCSP.


OCSP support for Lightweight CAs
--------------------------------

The initial release of the Dogtag lightweight CAs feature had OCSP
support for certificates issued by lightweight CAs.  It works
properly and there is nothing more to be said about it.


CRL support for lightweight CAs
-------------------------------

As mentioned in the introduction, certificates issued by lightweight
CAs are not included in the CRLs produced by Dogtag.  `Ticket
#1627`_ in the upstream Pagure tracks this issue.

.. _Ticket #1627: https://pagure.io/dogtagpki/issue/1627

The reason this was not implemented in the initial release (or
since) is that in the baseline case, a CRL can only include
certificates from a single CA.  Say we have the main CA
``CN=MainCA`` and lightweight sub-CA ``CN=SubCA``.  The CRL cannot
include certificates from both CAs, because a CRL is just a list of
serial numbers.

Indirect CRLs
^^^^^^^^^^^^^

There is a way around this limitation.  The `Certificate Issuer`_
CRL entry extension, if some other extensions on both the
certificate and CRL are set up *just right*, allows a CRL to include
certificates from multiple issuers.  Such CRLs are called *indirect
CRLs*.  Conforming applications are not required to support indirect
CRLs, and the extension is *critical* so there is a risk of
compatibility issues if we were to use indirect CRLs for conveying
revocation status of certificates issued by lightweight CAs.

.. _ Certificate Issuer: https://tools.ietf.org/html/rfc5280#section-5.3.3

Apart from client support for the Certificate Issuer extension the
other requirements for indirect CRLs to work are:

* The certificate's *CRL Distribution Points (CRLDP)* extension must
  include the ``cRLIssuer`` field and its value must match the
  issuer of the CRL.

* The CRL must include the *Issuing Distribution Point* CRL
  extension that asserts the ``indirectCRL`` boolean.  This is a
  critical extension.

* The trust anchor for the CRL must be the same as the trust anchor
  for the certificate.  This means that indirect CRLs cannot work
  for lightweight CAs that do not chain to the same CA.  This is
  only a potential problem if the lightweight CAs feature is
  enhanced to support hosting unrelated CAs (rather than sub-CAs).

So to use indirect CRLs some minor changes to certificate profiles
would be required.  But the changes would be the same for all
profiles and the content of the CRL Distribution Point extension
would be the same regardless of which lightweight CA issues the
certificate.

Separate CRLs
^^^^^^^^^^^^^

An alternative approach is to create a separate CRL for each
lightweight CA.  This would avoid compatibility issues caused by the
use of critical extensions that clients are not required to support.
It also avoids the trust anchor limitations that would arise when
hosting a lightweight CA that does not share a common trust root
with the CRL issuer.

From an implementation point of view there are two major challenges
with this approach.

1. Dogtag does not generate CRLs implicitly but currently requires
   explicit configuration for each CRL.  The configuration is not
   stored in LDAP but in the ``CS.cfg`` configuration file, so there
   is no way to dynamically configure new CRLs as new lightweight
   CAs are created.  

2. The content of the CRL Distribution Point extension will differ
   according to the CA that is issuing the certificate.  The CRLDP
   content is currently configured per-profile.  New profile
   components or enhancements to the existing CRLDP profile
   component will be required.

In my view it is not acceptable to have to define multiple profiles
differing only the CRL Distribution Point extension.  The CA issuing
the certificate should, by default, set any extensions that relate
specifically to itself, including the CRLDP (also *Authority Key
Identifier* and *Authority Information Access*).  For more
specialised use cases, the CRLDP content could be *overridden* or
*suppressed* on a per-profile basis.


Deciding the approach
^^^^^^^^^^^^^^^^^^^^^

Indirect CRLs is the lower-effort approach.  But before choosing it,
we ought to audit certificate verification libraries (especially
OpenSSL, NSS and other libraries used in Fedora, RHEL and other Red
Hat products) to see if they support indirect CRLs.  If support is
widespread, the approach is viable.  If support is not widespread,
it is not a good idea.

Thinking longer-term, this is a good opportunity to improve the
administrator experience.  Maybe now is a good time to implement
useful features like automatic CRL generation for each CA in a
Dogtag instance, and profile components that create a CRL
Distribution Point extension that points to the CRL for the CA that
is issuing the certificate.  The current configuration approach is
versatile and can handle all kinds of wild CRL scenarios.  But it is
*hostile* to getting things right for the common case.

This decision will probably not be mine to make because I will soon
be leaving the Dogtag team.  But I hope this post is useful to
whoever is involved in the eventual decision.


Profile changes
^^^^^^^^^^^^^^^

Both of the discussed approaches require some changes to profile
configuration.  Required profile changes means upgrade steps to
update them.  This can be tricky especially in mixed-version
topologies when new profile components (if any) are present on some
servers but not others.

The "do nothing" option
^^^^^^^^^^^^^^^^^^^^^^^

Lightweight CAs have been available for nearly 4 years.  I can only
recall one or two queries about lightweight CA CRL support.  To be
clear, it is a fair ask.  But it seems that OCSP is sufficient for
most customers.  Or perhaps there is a lack of awareness that CRLs
do not include certificates issued by lightweight CAs.  Whatever the
case, the low demand aligns with my own opinion that although CRL
support for lightweight CAs is a nice-to-have, it is not of critical
importance to many users or customers.


Conclusion
----------

In this post I identified two possible approaches to CRL support for
lightweight CAs.  Each approach has advantages, drawbacks and unique
challenges.  Never implementing it is also an option to be
considered because demand, though it does exist, seems low.

I haven't often discussed revocation in detail, so it is probably
worth mentioning other approaches besides CRLs and OCSP.

*Ephemeral PKI* avoids the problem by only issuing very short lived
certificates, e.g. one week, one day or even less!  Assuming keys
are rotated just as frequently, when certificate lifetimes approach
the "lag" time revocation solutions, the revocation solution is not
needed.

*CRLite* is an experimental revocation solution currently in
development.  It achieves fast and scalable revocation checking
through cascading Bloom filters produced by an *aggregator* that
records certificate revocations from one or more CAs.  The target
use case is in fact *all publicly trusted CAs* and Firefox Nightly
already uses the system (non-enforcing, telemetry-only by default).
Scott Helme wrote an `excellent blog post`_ about it and you can
read the `original paper`_ for the gory details.

.. _excellent blog post: https://scotthelme.co.uk/crlite-finally-a-fix-for-broken-revocation/
.. _original paper: https://obj.umiacs.umd.edu/papers_for_stories/crlite_oakland17.pdf

One final note.  I found some compliance issues with how the CRL
Distribution Point extension is configured in the default FreeIPA
certificate profiles.  A strict reading of `RFC 5280`_ suggests that
the CRL Distribution Point extension data produced by the default
FreeIPA profiles would lead to the certificate not being considered
in scope of the CRLs produced by Dogtag.  This issue is particular
to FreeIPA configuration, not a general problem with FreeIPA.  More
investiation is required and I will probably write a separate post
about this in the future.

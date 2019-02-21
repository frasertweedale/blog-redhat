---
tags: freeipa, certificates
---

Changing a CA's Subject DN; Part I: Don't Do That
=================================================

When you deploy an X.509 certificate authority (CA), you choose a
*Subject Distinguished Name* for that CA.  It is sometimes
abbreviated as *Subject DN*, *Subject Name*, *SDN* or just
*Subject*.

The Subject DN cannot be changed; it is "for life".  But sometimes
someone wants to change it anyway.  In this article I'll speculate
why someone might want to change a CA's Subject DN, discuss why it
is problematic to do so, and propose some alternative approaches.


What is the Subject DN?
-----------------------

A distinguished name (DN) is a sequence of sets of name attribute
types and values.  Common attribute types include *Common Name
(CN)*, *Organisation (O)*, *Organisational Unit (OU)*, *Country (C)*
and so on.  DNs are encoded in ASN.1, but have a well defined string
representation.  Here's an example CA subject DN::

  CN=DigiCert Global Root CA,OU=www.digicert.com,O=DigiCert Inc,C=US

All X.509 certificates contain an *Issuer DN* field and a *Subject
DN* field.  If the same value is used for both issuer and subject,
it is a *self-signed certificate*.  When a CA issues a certificate,
the *Issuer DN* on the issued certificate shall be the *Subject DN*
of the CA certificate.  This relationship is a "link" in the chain
of signatures from some *root CA* to *end entity* (or *leaf*)
certificate.

The Subject DN uniquely identifies a CA.  **It is the CA**.  A CA
can have multiple concurrent certificates, possibly with different
public keys and key types.  But if the Subject DN is the same, they
are just different certificates for a single CA.  Corollary: if the
Subject DN differs, it is a different CA *even if the key is the
same*.


CA Subject DN in FreeIPA
------------------------

A standard installation of FreeIPA includes a CA.  It can be a root
CA or it can be signed by some other CA (e.g. the Active Directory
CA of the organisation).  As of FreeIPA v4.5 you can specify any CA
Subject DN.  Earlier versions required the subject to start with
``CN=Certificate Authority``.

If you don't explicitly specify the subject during installation, it
defaults to ``CN=Certificate Authority, O=EXAMPLE.COM`` (replace
``EXAMPLE.COM`` with the actual realm name).


Why change the CA Subject DN?
-----------------------------

Why would someone want to change a CA's Subject DN?  Usually it is
because there is some organisational or regulatory requirement for
the Subject DN to have a particular form.  For whatever reason the
Subject DN doesn't comply, and now they want to bring it into
compliance.  In the FreeIPA case, we often see that the default CA
Subject DN was accepted, only to later realise that a different name
is needed.

To be fair, the FreeIPA installer does not prompt for a CA Subject
DN but rather uses the default form unless explicitly told otherwise
via options.  Furthermore, the CA Subject DN is not mentioned in the
summary of the installation parameters prior to confirming and
proceeding with the installation.  And there are the aforementioned
restrictions in FreeIPA < v4.5.  So in most cases where a FreeIPA
administrator wants to change the CA Subject DN, it is not because
*they chose* the wrong one, rather they were *not given an
opportunity* to choose the right one.


Implications of changing the CA Subject DN
------------------------------------------

In the X.509 data model the Subject DN is the essence of a CA.
So what happens if we do change it?  There are several areas of
concern, and we will look at each in turn.

Certification paths
~~~~~~~~~~~~~~~~~~~

Normally when you renew a CA certificate, you don't need to keep the
old CA certificates around in your trust stores.  If the new CA
certificate is within its validity period you can just replace the
old certificate, and everything will keep working.

But if you change the Subject DN, you need to keep the old
certificate around, because previously issued certificates will bear
the *old* Issuer DN.  Conceptually this is not a problem, but many
programs and libraries cannot cope with multiple subjects using the
same key.  In this case the only workaround is to reissue every
certificate, with the new Issuer DN.  This is a nightmare.

CRLs
~~~~

A *certificate revocation list* is a signed list of non-expired
certificates that have been revoked.  A CRL issuer is either the CA
itself, or a trusted delegate.  A CRL signing delegate has its own
signing key and an X.509 certificate issued by the CA, which asserts
that the subject is a CRL issuer.  Like certificates, CRLs have an
Issuer DN field.

So if the CA's Subject DN changes, then CRLs issued by that CA must
use the new name in the Issuer field.  But recall that certificates
are uniquely identified by the Issuer DN and Serial (think of this
as a composite primary key).  So if the CRL issuer changes (or the
issuer of the CRL issuer), all the old revocation information is
invalid.  Now you must maintain two CRLs:

- One for the old CA Subject.  Even after the name change, this CRL
  may grow as certificates that were issued using the old CA subject
  are revoked.

- One for the new CA Subject.  It will start off empty.

If a CRL signing delegate is used, there is further complexity.  You
need two separate CRL signing certificates (one with the old Issuer
DN, one with the new), and must 

Suffice to say, a lot of CA programs do not handle these scenarios
nicely or at all.

OCSP
~~~~

The *Online Certificate Status Protocol* is a protocol for checking
the revocation status of a single certificate.  Like CRLs, OCSP
responses may be signed by the issuing CA itself, or a delegate.

As in the CRL delegation case, different OCSP delegates must be used
depending on which DN was the Issuer of the certificate whose status
is being checked.  If performing direct OCSP signing, if identifying
the Responder ID by name, then the old or new name would be included
depending on the Issuer of the certificate.

Performing the change
~~~~~~~~~~~~~~~~~~~~~

Most CA programs do not offer a way to change the Subject DN.  This
is not surprising, given that the operation just doesn't fit into
X.509 at all, to say nothing of the implementation considerations
that arise.

It may be possible to change the CA Subject DN with some manual
effort.  In a follow-up post I'll demonstrate how to change the CA
Subject DN in a FreeIPA deployment.


Alternative approaches
----------------------

I have outlined reasons why renaming a CA is a Bad Idea.  So what
other options are there?

Whether any of the follow options are viable depends on the use case
or requirements.  They might not be viable.  If you have any other
ideas about this I would love to have your feedback!  So, let's look
at a couple of options.

Do nothing
~~~~~~~~~~

If you only want to change the CA Subject DN for cosmetic reasons,
don't.  Unless there is a clear business or organisational
imperative, just accept the way things are.  Your efforts would be
better spent somewhere else, I promise!


Re-chaining your CA
~~~~~~~~~~~~~~~~~~~

If there is a requirement for your **root** CA to have a Subject DN
of a particular form, you could create a CA that satisfies the
requirement somewhere else (e.g.  a separate instance of Dogtag or
even a standalone OpenSSL CA).  Then you can *re-chain* your FreeIPA
CA up to this new external CA.  That is, you renew the CA
certificate, but the issuer of the new IPA CA certificate is the new
external CA.

The new external CA becomes a trusted root CA, and your FreeIPA
infrastructure and clients continue to function as normal.  The
FreeIPA CA is now an *intermediate* CA.  No certificates need to be
reissued, although some server configurations may need to be updated
to include the new FreeIPA CA in their certificate chains.

Subordinate CA
~~~~~~~~~~~~~~

If certain end-entity certificates have to be issued by a CA whose
Subject DN meets certain requirements, you could create a
*subordinate CA* (or *sub-CA* for short) with a compliant name.
That is, the FreeIPA CA issues an intermediate CA certificate with
the desired Subject DN, and that CA issues the leaf certificates.

FreeIPA support Dogtag *lightweight sub-CAs* as of v4.4 and there
are no restrictions on the Subject DN (except uniqueness).  Dogtag
lightweight CAs live within the same Dogtag instance as the main
FreeIPA CA.  See ``ipa help ca`` for plugin documentation.  One
major caveat is that CRLs are not yet supported for lightweight CAs
(there is an `open ticket`_).

You could also use the FreeIPA CA to issue a CA certificate for some
other CA program (possible another deployment of Dogtag or FreeIPA).

.. _open ticket: https://pagure.io/dogtagpki/issue/1627


Conclusion
----------

In this post I explained what a CA's Subject DN is, and how it is an
integral part of how X.509 works.  We discussed some of the
conceptual and practical issues that arise when you change a CA's
Subject DN.  In particular, path validation, CRLs and OCSP are
affected, and a lot of software will break when encountering a "same
key, different subject" scenario.

The general recommendation for changing a CA's subject DN is
**don't**.  But if there is a real business reason why the current
subject is unsuitable, we looked at a couple of alternative
approaches that could help: re-chaining the CA, and creating
sub-CAs.

In my next post we will have an in-depth look how to change a
FreeIPA CA's Subject DN: how to do it, and how to deal with the
inevitable breakage.


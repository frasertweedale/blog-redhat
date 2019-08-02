---
tags: certificates, security
---

Certificates need not be limited to the CA's validity period
============================================================

All X.509 certificates have a ``notBefore`` and ``notAfter`` date.
These define the *validity period* of the certificate.  When we talk
about certificate *expiry*, we are talking about the ``notAfter``
date.  The question often arises: can a certificate's ``notAfter``
date exceed the ``notAfter`` date of the issuer's certificate?

The naïve intuition says, *surely a certificate's validity period
cannot exceed the CA's*.  But let's think it through, and look at
what these fields actually mean.  According to `RFC 5280
§4.1.2.5`_::

   The certificate validity period is the time interval
   during which the CA warrants that it will maintain
   information about the status of the certificate.

.. _RFC 5280 §4.1.2.5: https://tools.ietf.org/html/rfc5280#section-4.1.2.5

The whole section makes no mention of the issuer's ``notAfter`` date
or validity period.  It only says that the CA must maintain status
(i.e. revocation) information about the issued certificate until (at
least) the ``notAfter`` date.

But what if the CA certificate expires before an issued certificate?
One of two things happens:

1. The CA certificate got renewed and the verifier has a copy of the
   new certificate.  The certificate being verified is within its
   validity period and so is the CA certificate, so there is a
   certificate path and everything is fine.

2. The CA certificate was not renewed (or the verifier doesn't have
   the renewed certificate).  The certificate being verified is
   within its validity period, but the issuer certificate is *not*.
   So there is no certificate path; the certificate being verified
   cannot not be trusted.

So it is fine for issued certificate to have expiry dates beyond
that of the CA.

In fact, clamping the ``notAfter`` of issued certificates to the
``notAfter`` of the CA can cause operational challenges.  At the
same time as the CA needs renewal, so do potentially many issued
certificates!  You may end up with certificates with short validity
periods if the CA certificate is renewed close to its ``notAfter``
time, and a flood of renewals to perform at the same time.

There is one situation where it is required to clamp the
``notAfter`` of issued certificates to the issuer ``notAfter``.
This is when it is known that the issuer, including its CRL and OCSP
facilities, will be decommissioned shortly after the expiry of the
issuer certificate.  Otherwise, in light of the potential
operational hazards, I recommend issuing certificates with whatever
validity period is appropriate for the application, regardless of
when the issuer certificate expires.

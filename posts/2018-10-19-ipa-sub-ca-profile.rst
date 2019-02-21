---
tags: freeipa, certificates, profiles
---

Should FreeIPA ship a subordinate CA profile?
=============================================

In my `previous post`_ I discussed how to issue subordinate CA
(sub-CA) certificates from FreeIPA.  In brief, the administrator
must create and import a profile configuration for issuing
certificates with the needed characteristics.  The profile must add
a *Basic Constraints* extension asserting that the subject is a CA.

.. _previous post: 2018-08-21-ipa-subordinate-ca.html

After publishing that post, it formed the basis of an official `Red
Hat solution`_ (Red Hat subscription required to view).
Subsequently, an `RFE was filed`_ requesting a sub-CA profile to be
included by default in FreeIPA.  In this short post I'll outline the
reasons why this might not be a good idea, and what the profile
might look like if we did ship one.

.. _Red Hat solution: https://access.redhat.com/solutions/3572691
.. _RFE was filed: https://bugzilla.redhat.com/show_bug.cgi?id=1639441


The case against
----------------

The most important reason not to include a sub-CA profile is that it
will not be appropriate for many use cases.  Important attributes of
a sub-CA certificate include:

- validity period (how long will the certificate be valid for?)

- key usage and extended key usage (what can the certificate be used
  for?)

- path length constraint (how many further subordinate CAs may be
  issued below this CA?)

- name constraints (what namespaces can this CA issue certificates
  for?)

If we ship a default sub-CA profile in FreeIPA, all of these
attributes will be determined ahead of time and fixed.  There is a
good chance the values will not be appropriate, and the
administrator must create a custom profile configuration anyway.
Worse, there is a risk that the profile will be used without due
consideration of its appropriateness.

If we do nothing, we still have the blog post and official solution
to guide administrators through the process.  The administrator has
the opportunity to alter the profile configuration according to
their security or operational requirements.


The case for
------------

The RFE description states:

  Signing a subordinate CA's CSR in IdM is difficult and requires
  tinkering.  This functionality should be built in and present with
  the product.  Please bundle a subordinate CA profile like the one
  described in the [blog post].

I agree that Dogtag profile configuration is difficult, even obtuse.
It is not well documented and there is limited sanity checking.
There is no *"one size fits all"* when it comes to sub-CA profiles,
but can there be a *"one size fits most"*?  Such a profile might
have:

- path length constraint of zero (the CA can only issue
  leaf certificates)

- name constraints limiting DNS names to the FreeIPA domain (and
  subdomains)

- a validity period of two years

In terms of security these are conservative attributes but they
still admit the most common use case.  Two years may or may not be a
reasonable lifetime for the subordinate CA, but we have to choose
*some* fixed value.  The downside is that customers could use this
profile without being aware of its limitations (path length, name
constraints).  The resulting issues will frustrate the customer and
probably result in some support cases too.


Alternatives and conclusion
---------------------------

There is a middle road: instead of shipping the profile, we ship a
"profile assistant" tool that asks some questions and builds the
profile configuration.  Questions would include the desired validity
period, whether it's for a CA (and if so the path length
constraint), name constraints (if any), and so on.  Then it imports
the configuration.

There may be merit to this option, but none of the machinery exists.
The effort and lead time are high.  The other options: *do-nothing*
(really *improve and maintain documentation*), or shipping a default
sub-CA profile—are low effort and lead time.

In conclusion, I am open to either leaving sub-CA profiles as a
documentation concern, or including a conservative default profile.
But because there is no *one size fits all*, I prefer to leave
sub-CA profile creation as a documented process that administrators
can perform themselves—and tweak as they see fit.

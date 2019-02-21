---
tags: freeipa, certificates
---

Certificate renewal and revocation in FreeIPA
=============================================

A `recent FreeIPA ticket`_ has prompted a discussion about what
revocation behaviour should occur upon certificate renewal.  The
ticket reported a regression: when renewing a certificate, ``ipa
cert-request`` was no longer revoking the old certificate.  But is
revoking the certificate the correct behaviour in the first place?

.. _recent FreeIPA ticket: https://pagure.io/freeipa/issue/7482

This post discusses the motivations and benefits of automatically
revoking a principal's certificates when a new certificate is
issued.  It is assumed that subjects of certificates are FreeIPA
principals.  Conclusions do not necessarily apply to other
environments or use cases.

Description of current behaviour
--------------------------------

Notwithstanding the purported regression mentioned above, the
current behaviour of FreeIPA is:

- for host and service principals: when a new certificate is issued,
  revoke previous certificate(s)

- for user principals: *never* automatically revoke certificates

The revocation behaviour that occurs during ``ipa cert-request`` is
actually defined in ``ipa {host,service}-mod``.  That is, when a
``userCertificate`` attribute value is removed, the removed
certificates get revoked.


One certificate per service: a bad assumption?
----------------------------------------------

The automatic revocation regime makes a big assumption.  Host or
service principals are assumed to need only one certificate.  This
is usually the case.  But it is not inconceivable that a service may
need multiple certificates for different purposes.  The current
(intended) behaviour prevents a service from possessing multiple
valid (non-revoked) certificates concurrently.


Certificate issuance scenarios
------------------------------

Let us abandon the assumption that a host or service only needs one
certificate at a time.  There are three basic scenarios where
``cert-request`` would be revoked to issue a certificate to a
particular principal.  In each scenario, there are different
motivations and consequences related to revocation.  We will discuss
each scenario in turn.

Certificate for new purpose (non-renewal)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

A certificate is being requested for some new purpose.  The subject
may already have certs issued to it for other purposes.  Existing
certificates *should not be revoked*.  FreeIPA's revocation
behaviour excludes this use case for host and service certificates.

Renewal due to impending expiry
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

A certificate may be requested to renew an existing certificate.
After the new certificate is issued, it does no harm to revoke the
old certificate.  But it is *not necessary to revoke* it; it will
expire soon.

Renewal for other reasons
^^^^^^^^^^^^^^^^^^^^^^^^^

A certificate could be renewed in advance of its expiration time for
any reasons (e.g. re-key due to compromise, add a Subject
Alternative Name, etc.)  Conservatively, we'll lump all the possible
reasons together and say that it is *necessary to revoke* the
certificate that is being replaced.

What if the subject possesses multiple certificates for different
purposes?  Right now, for host and service principals we revoke them
all.


Proposed changes
----------------

A common theme is emerging.  When we request a certificate, we want
to revoke *at most one* certificate, i.e. the certificate being
renewed (if any).  This suggestion is applicable to service/host
certificates as well as user certificates.  It would admit the
*multiple certificates for different purposes* use case for all
principal types.

How do we get there from where we are now?

Observe that the ``ipa cert-request`` currently does not know (a)
whether the request is a renewal or (b) what certificate is being
renewed.  Could we make ``cert-request`` smart enough to guess what
it should do?  Fuzzy heuristics that could be employed to make a
guess, e.g. by examining certificate attributes, validity period,
the subject public key, the profile and CA that were used, and so
on.  The guessing logic would be complex, and could not guarantee a
correct answer.  It is not the right approach.

Perhaps we could remove all revocation behaviour from ``ipa
cert-request``.  This would actually be a matter of *suppressing*
the revocation behaviour of ``ipa {host,service}-mod``.  Revocation
has always been available via the ``ipa cert-revoke`` command.  This
approach makes revocation a separate, explicit step.

Note that renewals via *Certmonger* could perform revocation via
``ipa cert-revoke`` in the renewal helper.  If you had to re-key or
reissue a certificate via ``getcert resubmit``, it could revoke the
old certificate automatically.  The nice thing here is that there is
no guesswork involved.  Certmonger *knows what cert it is tracking*
so it can nominate the certificate to revoke and leave the subject's
other certificates alone.

A nice middle ground might be to add a new option to ``ipa
cert-request`` to specify the certificate that is being
renewed/replaced, so that ``cert-request`` can revoke just that
certificate, and remove it from the subject principal's LDAP entry.
The command might look something like::

  % ipa cert-request /path/to/req.csr \
      --principal HTTP/www.example.com \
      --replace "CN=Certificate Authority,O=EXAMPLE.COM;42"

The ``replace`` option specifies the issuer and serial number of the
certificate being replaced.  After the new certificate is issued,
``ipa cert-request`` would attempt to revoke the specified
certificate, and remove it from the principal's ``userCertificate``
attribute.  Certmonger would be able to supply the ``replace``
option (or whatever we call it).

For any of the above suggestions it would be necessary to
prominently and clearly outline the changes in release notes.  The
change in revocation behaviour could catch users off guard.  It is
important not to rush any changes through.  We'll need to engage
with our user base to explain the changes, and outline steps to
preserve the existing revocation behaviour if so desired.

``ipa {host,service}-mod`` changes
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Another (independent) enhancement to consider is an option to
suppress the revocation behaviour of ``ipa {host,service}-mod``, so
that certificates could be removed from host/service entries without
revoking them.  A simple ``--no-revoke`` flag would suffice.

Conclusion
----------

In this post I discussed how the current revocation behaviour of
FreeIPA prevents hosts and services from using multiple certificates
for different purposes.  This is not the majority use case but I
feel that we should support the use case.  And we can, with a
refinement of ``ipa cert-request`` behaviour.

We ought to make it possible to revoke *only the certificate being
renewed*.  We can do this by preventing ``ipa cert-request`` from
revoking certs and requiring a separate call to ``ipa cert-revoke``.
behaviour of ``cert-request``  Alternatively, we can add an option
to ``ipa cert-request`` for explicitly specifying the certificate(s)
to revoke.  In either case, the Certmonger renewal helpers can be
changed to ensure that renewals via Certmonger revoke the old
certificate (while leaving the subject's other certificates alone!)

What do you think of the changes I've suggested?  You can contribute
to the `discussion on the *freeipa-devel* mailing list`_.

.. _discussion on the *freeipa-devel* mailing list: https://lists.fedoraproject.org/archives/list/freeipa-devel@lists.fedorahosted.org/thread/G2BXRJNU5ATVXRNUPGE2Y4V3YJVXR7EC/

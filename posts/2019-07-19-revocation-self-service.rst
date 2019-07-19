Designing revocation self-service for FreeIPA
=============================================

The FreeIPA team recently received a `feature request`_ for
self-service certificate revocation.  At the moment, revocation must
be performed by a privileged user with the ``Revoke Certificate``
permission.  The one exception to this is that a host principal can
revoke certificates for the same hostname.  There are no expections
when it comes to user certificates.

In this post I'll discuss revocation self-service and how it might
work in FreeIPA.

.. _feature request: https://bugzilla.redhat.com/show_bug.cgi?id=1730363

Requirements and approaches for self-service
--------------------------------------------

It is critical to avoid scenarios where a user could revoke a
certificate they should not be able to revoke; this would constitute
a Denial-of-Service (DoS) vulnerability.  Therefore FreeIPA must
establish that the principal issuing the revocation request has
authority to revoke the nominated certificate.  Conceptually, there
are several ways we might establish that authority.  Each scenario
has trade-offs, either fundamental to the scenario or specific to
FreeIPA.

Proof of possession
~~~~~~~~~~~~~~~~~~~

Proof of possession (PoP) establishes a cryptographic proof that the
operator possess the private key for the certificate to be revoked.
Either they are rightful subject of the certificate, in which case
it is reasonable to service their revocation request.  Or they have
compromised the subject's key, in which case it is reasonable to
revoke it anyway.

There are challenges implementing a POP-based revocation system.  A
single request is not enough.  The client must request a nonce
(which the server must remember), and the subsequent message must
contain a signature over that nonce.  This complicates the command
interface.  And the user interface must consider how to access the
key, i.e. it must learn arguments related to paths, passphrases, and
so on.

Finally, there is an important use case this scenario does not
handle: when the user no longer has control of their private key
(they deleted it, forgot the passphrase, etc.)


Certificate inspection
~~~~~~~~~~~~~~~~~~~~~~

The revocation command could inspect the certificate and decide if
it "belongs to" the requestor.  This must be done with extreme care,
because a false-positive is equivalent to a DoS vulnerability.  For
example, merely checking that the UID or CN attribute in the
certificate Subject DN corresponds to the requestor is inadequate.

It is hard to attain 100% certainty, especially considering
administrators can create custom certificate profiles.  But there
are some options that seem safe enough to implement.  It should be
reasonable to authorise the revocation if:

- The Subject Alternative Name (SAN) extension contains a
  ``KRB5PrincipalName`` or ``UPN`` value equal to the authenticated
  principal.  FreeIPA supports such certificates out of the box,
  contingent on the CSR including these data.

- The SAN contains a ``rfc822Name`` (email address) equal to one
  of the user's email addresses.  Again, FreeIPA supports this with
  the same CSR caveat.

- The SAN contains a ``directoryName`` (DN) equal to the user's full
  DN in the FreeIPA LDAP directory.  Supported, with CSR caveat.

- The certificate Subject DN is equal to the user's full DN in the
  FreeIPA LDAP directory.  Supported with a custom profile having
  ``subjectNameDefaultImpl`` configuration like (wrapped for
  display)::

    policyset.serverCertSet.1.default.params.name=
      UID=$request.req_subject_name.cn$,
      CN=users,CN=accounts,DC=example,DC=com

The CSR caveat presents a burden to users: they must lovingly
handcraft their CSR to include the relevant data.  To say the tools
have poor usability in this area is an understatement.  But the SAN
options are supported out of the box by the default user certificate
profile ``IECUserRoles`` (don't ask about the name).

On the other hand, the Subject DN approach requires a custom profile
but nothing special needs to go in the CSR.  A Subject DN of
``CN=username`` will suffice.


Audit-based approach
~~~~~~~~~~~~~~~~~~~~

When issuing a certificate via ``ipa cert-request``, there are two
principals at play: the *operator* who is performing the request,
and the *subject* principal who the certificate is for.  (These
could be the same principal).  Subject to organisational security
policy, it may be reasonable to revoke a certificate if *either* of
these principals requests it.

Unfortunately, in FreeIPA today we do not record these data in a way
that is useful to make a revocation authorisation decision.  In the
future, when FreeIPA authenticates to Dogtag using GSS-API and a
Kerberos proxy credential for the operator (instead of the IPA RA
agent credential we use today), we will be able to store the needed
data.  Then it may be feasible to implement this approach.  Until
then, forget about it.


The way forward
---------------

So, which way will we go?  Nothing is decided yet (including
*whether to implement this at all*).  If we go ahead, I would like
to implement the *certificate inspection* approach.  Proof of
possession is tractable, but a lot of extra complexity and probably
a usability nightmare for users.  The audit-based approach is
infeasible at this time, though it is a solid option if/when the
right pieces are in place.  Certificate inspection carries a risk of
DoS exposure through revocation of inappropriate certificates, but
if we carefully choose which data to inspect and match, the risk is
minimised while achieving satisfactory usability.

---
tags: freeipa, dogtag, internals
---

FreeIPA PKI: current plans and a future vision
==============================================

FreeIPA's X.509 PKI features (based on Dogtag Certificate System)
continue to be an area of interest for users and customers.  In this
post I summarise recently-added PKI features in FreeIPA, work in
progress, and what we plan to do in future releases.  Then I will
outline my personal vision for what the future of PKI in FreeIPA
should look like, noting how it will address pain points and
limitations of the existing architecture.


Recent changes and work in progress
-----------------------------------

In the past only a single certificate profile was supported
(appropriate for TLS-enabled services) but as of FreeIPA 4.2
multiple certificate profiles are supported (including custom
profiles), as are user certificates.  *CA ACL* rules define which
profiles can be used to issue certificates to particular principals
(users, groups, hosts, hostgroups and/or services).  The FreeIPA
framework (not Dogtag) enforces CA ACLs.

Custom profiles support means that the PKI can be used for a huge
number of use cases, but it is still up to the user or operator to
provide a suitable PKCS #10 *certificate signing request* (CSR).

I am currently working on implementing support for lightweight
sub-CAs in Dogtag and FreeIPA so that sub-CAs can be easily created
and used to issue certificates.  The CA ACLs concept will be
extended to include sub-CAs so that use of certain profiles can be
restricted to particular CAs.


Problems with the current architecture
--------------------------------------

To put this this all in context, please study the following crappy
diagram of the current FreeIPA PKI architecture::

  +----------+
  |   User   |
  |          |  1. Generate CSR
  | +------+ |     (somehow... poor user)
  | | krb5 | |
  | |ticket| |
  +-+--|---+-+
       |                           +-----------+
       | 2. ipa cert-request       |           |
       |    (CSR payload)          |   389DS   |
       v                           |           |
  +--------------------+           +-----------+
  |  FreeIPA   +-------+                 ^
  |            |krb5   |                 |
  |            |proxy  <-----------------+
  | +-------+  |ticket |   3. Validate CSR
  | |RA cert|  +-------+   4. Enforce CA ACLs
  +-+---|---+----------+
        |
        | 5. Dogtag cert request
        |    (CSR payload)
        v
  +--------+
  | Dogtag | 6. Issue certificate
  +--------+


The Dogtag CA is the entity that actually issues certificates.
FreeIPA requests certificates from Dogtag with the *RA Agent*
credential (an X.509 client certificate) with which the FreeIPA
framework has authority to use any profile that accepts RA Agent
authentication to issue a certificate.  This is a longstanding
violation of an important framework design principle: the framework
should only ever operate with the privileges of the authenticated
principal.

Another problem is that users are burdened with the responsibility
of crafting a CSR that is correct for the profile that will be used.
This is a nontrivial task even for common types of certificates - it
is downright painful once exotic extensions come into play.  There
is a lot that a user can get wrong, which may result in an invalid
CSR or cause Dogtag to reject a request because it does not contain
the data required by the profile. Furthermore it is reasonable to
expect that any data that appear on a certificate are (or could be)
stored in the directory, and could be populated into a certificate
automatically according to the profile rather than by copying the
data from the CSR.

On the topic of exotic extensions: although FreeIPA ensures that
requested extension values of common extensions are appropriate and
correspond to the subject principal's attributes (e.g. making sure
that all *Subject Alternative Names* are valid), no validation of
uncommon extensions is performed.  Nor should it be - not in the
FreeIPA framework, especially; the complexity of validating
extension values does not belong here, and validation is impossible
if we have not yet taught FreeIPA about the extension or how to
validate it, or if the validation involves custom LDAP schema.  This
is the problem we have with the *IECUserRoles* extension which we
support with a profile but cannot validate - user self-service must
be prohibited for profiles like this and certificate administrators
must be trusted to only issue certificates with appropriate
extension values.


Planned work to address (some of) these issues
----------------------------------------------

The framework privilege separation (lack thereof) issue is tracked
in FreeIPA `ticket #5011`_: *[RFE] Forward CA requests to Dogtag or
helper by GSSAPI*.  This will remove the *RA Agent* credential and
CA ACL enforcement logic from FreeIPA.  Instead, the framework will
obtain a proxy ticket to talk to Dogtag on behalf of the requestor
principal, and Dogtag will authenticate the user, consult CA ACLs
and (if all is well) continue with the certificate issuance process
(which could still fail if the data in the CSR does not satisfy the
profile requirements).

Implementation details for this ticket are not yet worked out but it
will involve creating a service principal for Dogtag and giving
Dogtag access to a keytab, performing GSSAPI authentication
(probably in a Java servlet *realm* implementation) and providing a
new profile authorisation class to read and enforce CA ACLs.  Tomcat
configuration and FreeIPA profile configurations will have to be
updated (during upgrade) to use the new classes.

.. _ticket #5011: https://fedorahosted.org/freeipa/ticket/5011


`Ticket #4899`_: *[RFE] mechanism to map principal info into
certificate requests* was filed to improve user experience when
creating CSRs for a particular profile.  An ``openssl req``
configuration file template could be stored for each profile and a
command added to fill out the template and return the appropriate
config for a given user, host or service.  We could go further and
supply config templates for other programs, or even create the whole
CSR at once.  Or even make it part of the ``cert-request`` command,
bypassing a number of steps!  The point is that there is currently a
lot of busy-work around requesting certificates that is not
necessary, and we can save *all* certificate users time and pain by
improving the process.

.. _Ticket #4899: https://fedorahosted.org/freeipa/ticket/4899


With these enhancements, the architecture diagram changes to remove
the RA certificate and provide assistance to the user in generating
the CSR (which is abstracted as the user reading data from 389DS)::

  +----------+
  |   User   | 1a. Read CSR template / attributes
  |          |<--------------------------+
  | +------+ |                           |
  | | krb5 | |                           |
  | |ticket| | 1b. Generate CSR          |
  +-+--|---+-+                           |
       |                                 |
       | 2. ipa cert-request             |
       |    (CSR payload)                |
       v                                 |
  +-----------+                          |
  |  FreeIPA  |                          |
  |           |                    +-----------+
  |    +------+                    |           |
  |    |krb5  |  3. Validate CSR   |   389DS   |
  |    |proxy <------------------->|           |
  |    |ticket|                    +-----------+
  +----+--|---+                          ^
          |                              |
          | 4. Dogtag cert request       |
          |    (CSR payload)             |
          v                              |
  +--------------------+                 |
  |  Dogtag    +-------+                 |
  |            |krb5   |                 |
  |            |proxy  <-----------------+
  |            |ticket |    5. Enforce CA ACLs
  |            +-------+
  +--------------------+
    6. Issue certificate


Future of FreeIPA PKI: my vision
--------------------------------

There are still a number of issues that the improved architecture
does not address.  The data in CSRs still have to be *just right*.
There is no way to validate exotic or unknown extension data,
limiting use cases or restricting user self-service and burdening
certificate issuers with the responsiblity of getting it right.
There is no way to pull data from custom LDAP schema into
certificates or even to automatically include data that we *know* is
in the directory on certificates (e.g. email, KRB5PrincipalName or
other kinds of alternative names).

The central concept of my vision for the future of FreeIPA's PKI is
that Dogtag should read from LDAP all the data it needs to produce a
certificate according to the nominated profile (except for the
subject public key which must be supplied by the requestor).  This
relieves the FreeIPA framework and Dogtag of most validation
requirements, because we would ignore all data submitted except for
the subject public key, subject principal, requestor principal and
profile ID (CA ACLs would still need to be enforced).

In this architecture the PKCS #10 CSR devolves to a glorified public
key format.  In fact the planned CSR template feature is completely
subsumed!  We would undoubtedly continue to support PKCS #10 CSRs,
and it would make sense to continue validating aspects of the CSR to
catch obvious user errors; but this would be a UX nicety, not an
essential security check.

The architecture sketch now becomes::

  +----------+
  |   User   |
  |          | 1. Generate keypair
  | +------+ |
  | | krb5 | |
  | |ticket| |
  +-+--|---+-+
       |
       | 2. ipa cert-request
       |    (PUBKEY payload)
       v
  +--------------+
  |   FreeIPA    |
  |              |                 +-----------+
  | +----------+ |                 |           |
  | |krb5 proxy| |                 |   389DS   |
  | |  ticket  | |                 |           |
  +-+----|-----+-+                 +-----------+
         |                               ^
         | 3. Dogtag cert request        |
         |    (PUBKEY payload)           |
         v                               |
  +--------------------+                 |
  |  Dogtag    +-------+                 |
  |            |krb5   |                 |
  |            |proxy  <-----------------+
  |            |ticket |    4. Enforce CA ACLs
  |            +-------+    5. Read data to be included on cert
  +--------------------+
    6. Issue certificate


Consider the *IECUserRoles* example under this new architecture and
observe the following advantages:

- The user is relieved of the difficult task of producing a CSR
  with exotic extension data.

- The profile reads the needed data (assuming it exists in standard
  or custom schema), allowing *IECUserRoles* or other exotic
  extensions to be easily supported.

- Because we are not accepting raw extension data that cannot be
  validated, user self-service can be allowed (appropriate write
  access controls must still exist for the attributes involved,
  though) and admins are relieved of crafting or verifying the
  correct extension values.

In terms of implementation, over and above what was already planned
this architecture will require several new Dogtag profile policy
modules to be implemented, and these will be more complex (e.g. they
will read data from LDAP).  Pleasantly, these do not actually have
to be implemented in or be formally a part of Dogtag - we can write,
maintain and ship these Java classes as part of FreeIPA and easily
configure Dogtag to use them.

In return we can remove a lot of validation logic from FreeIPA and
profile configurations will be easier to write and understand
(decide which extensions you want and trust the corresponding
profile policy class to "do the right thing").

Importantly, it becomes possible for administrators to provide their
own profile components implementing the relevant Java interface that
read custom schema into esoteric or custom X.509 extensions,
supporting any use case that we (the FreeIPA developers) don't know
about or can't justify the effort to implement.  Although this is
*technically* possible today, moving to this approach in FreeIPA
will simplify the process and provide significant prior art and
expertise to help users or customers who want to do this.


Concluding thoughts
-------------------

There are plans for other FreeIPA PKI features that I have not
mentioned in this post, such as Let's Encrypt / ACME support, or an
interactive "profile builder" feature.  The proposed architecture
changes do not directly impact these features although simplifying
profile configuration in any way would make the profile builder a
more worthwhile / tractable feature.

The vision I have outlined here is my own at this point - although I
have hinted at it over the past few months this post is my first
real effort to expound and promote it.  It is a significant shift
from how we are currently doing things and will be a substantial
amount of work but I hope that people will see the value in reducing
user and administrator workload and being able to support new X.509
use cases without significant ongoing effort by the FreeIPA or
Dogtag development teams.

Feedback on my proposal is strongly encouraged!  You can leave
comments here, send an email to me (``ftweedal@redhat.com``) or the
FreeIPA development mailing list (``freeipa-devel@lists.fedorahosted.org``) or
continue the discussion on IRC (``#freeipa`` on Freenode).

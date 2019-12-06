---
tags: certificates, acme, freeipa
---

Plans for ACME support in FreeIPA
=================================

In this post I outline the plans for ACME support in FreeIPA.  It's
not intended as a general introduction to ACME or a deep dive into
the protocol; if you don't know what ACME is, the `Wikipedia page`_
is a good place to start.  Instead this post will focus on how ACME
could fit into enterprise environments, and our initial plans for
ACME support in `FreeIPA`_.

.. _Wikipedia page: https://en.wikipedia.org/wiki/Automated_Certificate_Management_Environment
.. _FreeIPA: https://www.freeipa.org/page/Main_Page


ACME in the enterprise
----------------------

*Automated Certificate Management Environment* or *ACME* (defined in
`RFC 8555`_) is a Certificate Authority (CA) protocol for automated
DNS name validation and certificate issuance.  It was first used by
`Let's Encrypt`_, a free publicly-trusted CA.  And ACME is
increasingly supported by other CAs.  Also, some enterprises are
interested in ACME to simplify certificate issuance within their
organisation.

.. _Let's Encrypt: https://letsencrypt.org/
.. _RFC 8555: https://tools.ietf.org/html/rfc8555

Therefore we are planning to implement ACME support in FreeIPA.  It
took us a long time to reach this point, because it was not clear
what we should do.  One of the main problems ACME solves—automated
DNS name validation—doesn't have the same importance in enterprise
environments where systems and services can already prove their
identity to a CA.

The other main part of ACME is the certificate request and issuance
part, which is already a solved problem.  That said, consolidation
around ACME and the value of server-integrated clients is a good
reason to adopt ACME, even if the name validation parts don't solve
an acute problem.

The "impedence mismatch" of the name validation parts of ACME in
enterprise environments has been recognised by the IETF ACME Working
Group.  There is an active Internet-Draft for an `"authority token"
challenge type`_.  This challenge type allows a client to present to
the ACME CA a verificable token, issued by a *Token Authority*, that
authorises the client to use a particular name.  But this
specification is still in development and it does not answer
questions like how the Token Authority decides whether or not to
grant an authorisation.

.. _"authority token" challenge type: https://datatracker.ietf.org/doc/draft-ietf-acme-authority-token/

So at this stage we have no firm idea of what "enterprise ACME"
should be.  We could make something up, but we prefer to do work
that is driven by (or anticipates) real customer requirements.
Although lots of customers have asked for or expressed interest in
ACME, noone has expressed a clear picture of how it should work with
their enterprise identity management.


Basic ACME
----------

So we will infer the simplest requirement.  Customers want ACME
support in FreeIPA, so we will give them the ACME they already know.
ACME clients are essentially anonymous and have no association with
enterprise identities.  Clients must perform DNS name validation
challenges just as they would if they were talking to a public CA
like Let's Encrypt.  The ACME service will validate the challenges
in the same way under the prevailing DNS view, which may be
different from the DNS view that a public CA would see.

When issuance is approved, the ACME service acts as a Registration
Authority (RA) and issues the certificate.  The client has no
control over the profile used.

Additional authentication, authorisation or account binding layers
will be deferred.  We can implement them when we know what they
should be.  If we build this "basic ACME" support, and customers
start using it, then hopefully they will tell us what they need more
control over.  When a clear picture of what "enterprise ACME" should
be emerges, we can be confident that we are implementing the right
thing.


Dogtag ACME service
-------------------

Already a lot of work has been done implementing an `ACME service in
Dogtag`_.  Although it lives in the main Dogtag repository, this is
essentially a separate server.  It can be configured with different
database backends (e.g. PostgreSQL, MongoDB) and different issuance
backends (Dogtag, OpenSSL, or even another ACME server).

.. _ACME service in Dogtag: https://www.dogtagpki.org/wiki/ACME

This work will be the core of the FreeIPA ACME service.  We will
deploy the ACME service on FreeIPA CA servers and expose it via the
Apache front end.


Additional work required for FreeIPA
------------------------------------

Although the core of the Dogtag ACME service has already been
implemented there is still a lot of work to do for the FreeIPA use
case.

LDAP database backend
^^^^^^^^^^^^^^^^^^^^^

We need to implement an LDAP database backend for the Dogtag ACME
service.  This includes devising the LDAP attribute and object class
schemas.  I'm currently working on this part.

There are clear advantages to using an LDAP database.  First, in a
FreeIPA deployment we already have LDAP databases configured, and
replication established, for Dogtag and FreeIPA.  And we do not want
to introduce and configure new dependencies, especially a database
server e.g. PostgreSQL.

LDAP configuration backend
^^^^^^^^^^^^^^^^^^^^^^^^^^

In addition to the storage of ACME objects, we also want the ACME
service configuration to be stored in LDAP.  This ensures a
consistent configuration across the topology.  Taking advantage of
LDAP replication and using a persistent search will ensure that
configuration changes (e.g. enable/disable the service or change the
profile to use) are applied across the topology almost immediately.

Dogtag backend authentication
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The Dogtag CA backend for the ACME service currently supports
password authentication.  This will not do.  It must be enhanced to
support another form of authentication.  Certificate authentication
seems an obvious target but it presents some challenges.  First, we
cannot use the IPA RA certificate as-is.  The Java TLS client
implementation we use uses NSS, and the IPA RA certificate and key
are in PEM format.  So we would need to:

- Make another copy of the IPA RA certificate in an NSS DB (nope)

- Add support for PEM certificates in the Java TLS client (maybe,
  and we would have to do some SELinux-fu too)

- Create a dedicated RA agent account and certificate for the ACME
  service (nope)

Alternatively we should pursue GSS-API (Kerberos) authentication.
We would need to implement support for this in the Java PKI client
libraries.  But we already know we want to get there one day.  And
when we get there, we want to do away with the IPA RA credential.
It might be worth the up-front effort to implement GSS-API
authentication for the ACME RA and avoid the long-term challenges
presented by certificate authentication.

The decision on which way we will go has not been made yet.


Lightweight CA support
^^^^^^^^^^^^^^^^^^^^^^

The Dogtag CA backend for the ACME service will be enhanced to allow
configuration of the (lightweight) CA to use for issuance.  This
will allow administrators to use a dedicated sub-CA for ACME
certificates.


Adding ``ipa-ca.$DOMAIN`` to the HTTP certificate
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

ACME requires TLS to authenticate the server to the client and
secure the connection.  In the FreeIPA deployment, the CA
capabilities are accessed via the ``ipa-ca.$DOMAIN`` DNS name.  This
is an A/AAAA record pointing to the servers that have the CA role
installed.  So if your domain name is ``example.org`` the ACME
service will be hosted at ``https://ipa-ca.example.org/acme`` (or
something like that).

This means that the DNS name ``ipa-ca.$DOMAIN`` must be added to the
Subject Alternative Name extension in the HTTP certificate on every
FreeIPA CA server.  For the sake of simplicity we will actually add
the name on the HTTP certificate on *all FreeIPA servers* whether
they have the CA role or not.  This will avoid having to issue a new
certificate when a replica without the CA role gets promoted to a CA
server.  Having the name on the certificate of a non-CA server has
no operational impact and minimal security risk.

In terms of implementation, for new replicas it is trivial to create
the Certmonger tracking request with the DNS name.  Some tweaks to
CSR validation may be required to allow FreeIPA servers to use the
name.  For upgrade, we will need to add the name to the Certmonger
tracking request *and* resubmit the request.


ACME certificate profile
^^^^^^^^^^^^^^^^^^^^^^^^

We need to define and install a default certificate profile for use
with ACME.  In particular, it must handle empty Subject DNs in CSRs;
some ACME clients including the popular Certbot generate CSRs with
empty subjects.  Furthermore the default validity period will be
around 3 months, in line with the Let's Encrypt profile and in
recognition of how increased automation allows certificate lifetimes
to be reduced, limiting security risks associated with long
certificate lifetimes.


FreeIPA management API and commands
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

We need to implement commands for administrators to configure the
ACME service.  The ACME service will be automatically deployed on
all CA servers, but by default will not service requests.  API
methods and corresponding CLI commands are needed to:

- enable or disable the service
- configure which ACME challenges are enabled
- configure the certificate profile and (lightweight) CA to use


Pruning expired certificates
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

ACME will typically be used to issue (many) short-lived
certificates.  If we do not prune expired certificates from the
database the disk usage will continue to grow, possibly too much.
So we want a procedure to prune expired certificates from the Dogtag
CA certificate database.  The pruning feature should be able to be
turned on or off depending on the organisation's needs.

Similarly, we want to prune expired authorisations, challenges and
orders from the ACME database.  Perhaps inactive accounts too.


Conclusion
----------

So, those are the plans for ACME support in FreeIPA.  There is a lot
of work to do.  I'm hoping to make good progress in the next few
months.  I look forward to giving progress updates and demos in
early 2020.

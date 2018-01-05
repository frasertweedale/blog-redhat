Implications of Common Name deprecation for Dogtag and FreeIPA
==============================================================

Or, *``ERR_CERT_COMMON_NAME_INVALID``, and what we are doing about
it.*

Google Chrome version 58, released in April 2017, removed support
for the X.509 certificate Subject **Common Name (CN)** as a source
of naming information when validating certificates.  As a result,
certificates that do not carry all relevant domain names in the
**Subject Alternative Name** (SAN) extension result in validation
failures.

At the time of writing this post Chrome is just the first mover, but
Mozilla Firefox and other programs and libraries will follow suit.
The public PKI used to secure the web and other internet
communiations is largely unaffected (browsers and CAs moved a long
time ago to ensure that certificates issued by publicly trusted CAs
carried all DNS naming information in the SAN extension), but some
enterprises running internal PKIs are feeling the pain.

In this post I will provide some historical and technical context to
the situation, and explain what we are are doing in Dogtag and
FreeIPA to ensure that we issue valid certificates.


Background
----------

X.509 certificates carry subject naming information in two places:
the **Subject Distinguished Name (DN)** field, and the **Subject
Alternative Name** extension.  There are many types of attributes
available in the DN, including *organisation*, *country*, and
*common name*.  The definitions of these attribute types came from
X.500 (the precursor to LDAP) and all have an ASN.1 representation.

Within the X.509 standard, the CN has no special interpretation, but
when certificates first entered widespread use in the SSL protocol,
it was used to carry the domain name of the subject site or service.
When connecting to a web server using TLS/SSL, the client would
check that the CN matches the domain name they used to reach the
server.  If the certificate is chained to a trusted CA, the
signature checks out, and the domain name matches, then the client
has confidence that all is well and continues the handshake.

But there were a few problems with using the Common Name.  First,
what if you want a certificate to support multiple domain names?
This was especially a problem for virtual hosts in the pre-`SNI`_
days where one IP address could only have one certificate associated
with it.  You can have multiple CNs in a Distinguished Name, but the
semantics of X.500 DNs is strictly heirarichical.  It is not an
appropriate use of the DN to cram multiple, possibly
non-hierarchical domain names into it.

.. _SNI: https://en.wikipedia.org/wiki/Server_Name_Indication

Second, the CN in X.509 has a length limit of 64 characters.  DNS
names can be longer.  The length limit is too restrictive,
especially in the world of IaaS and PaaS where hosts and services
are spawned and destroyed *en masse* by orchestration frameworks.

Third, some types of subject names do not have a corresponding X.500
attribute, including domain names.  The solution to all three of
these problems was the introduction of the *Subject Alternative
Name* X.509 extension, to allow more types of names to be used in a
certificate.  (The SAN extensions is itself extensible; apart from
DNS names other important name types include IP addresses, email
addresses, URIs and Kerberos principal names).  TLS clients added
support for validating SAN DNSName values in addition to the CN.

The use of the CN field to carry DNS names was never a standard.
The Common Name field does not have these semantics; but using the
CN in this way was an approach that worked.  This interpretation was
later formalised by the CA/B Forum in their *Baseline Requirements*
for CAs, but only as a reflection of a current practice in SSL/TLS
server and client implementations.  Even in the Baseline
Requirements the CN was a second-class citizen; they mandated that
if the CN was present at all, it must reflect one of the DNSName or
IP address values from the SAN extension.  All public CAs had to
comply with this requirement, which is why Chrome's removal of CN
support is only affecting private PKIs, not public web sites.

.. _RFC 2818: https://tools.ietf.org/html/rfc2818#page-5


Why remove CN validation?
-------------------------

So, Common Name was not ideal for carrying DNS naming information,
but given that we now have SAN, was it really necessary to deprecate
it, and is it really necessary to follow through and actually stop
using it, causing non-compliant certificates that were previously
accepted to now be rejected?

The most important reason for deprecating CN validation is the X.509
**Name Constraints** extension.  Name Constraints, if they appear in
a CA certificate or intermediate CA certificate, constrain the valid
subject names on leaf certificates.  Various name types are
supported including DNS names; a DNS name constraint restricts the
domain of validity to the domain(s) listed and subdomains thereof.
For example, if the DNS name ``example.com`` appears in a CA
certificate's Name Constraints extension, leaf certificates with a
DNS name of ``example.com`` or ``foo.example.com`` could be valid,
but a DNS name of ``foo.example``**``.net``** could not be valid.
Conforming X.509 implementations must enforce these constraints.

But these constraints only apply to SAN DNSName values, **not to the
CN**.  This is why accepting DNS naming information in the CN had to
be deprecated - the name constraints cannot be properly enforced!

So back in May 2000 the use of Common Name for carrying a DNS name
was `deprecated by RFC 2818`_.  Although it deprecated the practice
this RFC **required** clients to fall back to the Common Name if
there were no SAN DNSName values on the certificate.  Then in 2011
`RFC 6125`_ removed the requirement for clients to fall back to the
common name, making this optional behaviour.  Over recent years,
some TLS clients began emitting warnings when they encountered
certificates without SAN DNSNames, or where a DNS name in the CN did
not also appear in the SAN extension.  Finally, Chrome has become
the first widely used client to remove support.

.. _deprecated by RFC 2818: https://tools.ietf.org/html/rfc2818#section-3.1
.. _RFC 6125: https://tools.ietf.org/html/rfc6125#section-6.4.4

Despite more than 15 years notice on the deprecation of this use of
Common Name, a lot of CA software and client tooling still does not
have first-class support for the SAN extension.  Most tools used to
generate CSRs do not even ask about SAN, and require complex
configuration to generate a request bearing the SAN extension.
Similarly, some CA programs does not do a good job of issuing
RFC-compliant certificates.  Right now, this includes Dogtag and
FreeIPA.


Subject Alternative Name and FreeIPA
------------------------------------

For some years, FreeIPA (in particular, the default profile for host
and service certificates, called ``caIPAserviceCert``) has supported
the SAN extension, but the client is required to submit a CSR
containing the desired SAN extension data.  The names in the CSR
(the CN and all alternative names) get validated against the subject
principal, and then the CA would issue the certificate with exactly
those names.  There was no way to ensure that the domain name in the
CN was also present in the SAN extension.

We could add this requirement to FreeIPA's CSR validation routine,
but this imposes an unreasonable burden on the user to "get it
right".  Tools like OpenSSL have poor usability and complex
configuration.  Certmonger supports generating a CSR with the SAN
extension but it must be explicitly requested.  For FreeIPA's own
certificates, we have (in recent major releases) ensured that they
have contained the SAN extension, but *this is not the default
behaviour* and that is a problem.

FreeIPA 4.5 brought with it a **CSR autogeneration** feature that,
for a given certificate profile, lets the administrator specify how
to construct a CSR appropriate for that profile.  This reduces the
burden on the end user, but they must still opt in to this process.


Subject Alternative Name and Dogtag
-----------------------------------

Until Dogtag 10.4, there were two ways to produce a certificate with
the SAN extension.  One was the ``SubjectAltNameExtDefault`` profile
component, which, for a given profile, supports a fixed number of
names, either hard coded or based on particular request attributes
(e.g. the CN, the email address of the authenticated user, etc).
The other was the ``UserExtensionDefault`` which copies a given
extension from the CSR to the final certificate verbatim (no
validation of the data occurs).  We use ``UserExtensionDefault`` in
FreeIPA's certificate profile (all names are validated by the
FreeIPA framework before the request is submitted to Dogtag).

Unfortunately, ``SubjectAltNameExtDefault`` and
``UserExtensionDefault`` are not compatible with each other.  If a
profile uses both and the CSR contains the SAN extension, issuance
will fail with an error because Dogtag tried to add two SAN
extensions to the certificate.

In Dogtag 10.4 we introduced a new profile component that improves
the situation, especially for dealing with the removal of client CN
validation.  The ``CommonNameToSANDefault`` will cause any profile
that uses it to examine the Common Name, and if it looks like a DNS
name, it will add it to the SAN extension (creating the extension if
necessary).

Ultimately, what is needed is a way to define a certificate profile
that just makes the right certificate, without placing an undue
burden on the client (be it a human user or a software agent).  The
complexity and burden should rest with Dogtag, for the sake of all
users.  We are gradually making steps toward this, but it is still a
long way off.  I have discussed this utopian vision `in a previous
post`_.

.. _in a previous post: 2015-11-04-freeipa-pki-future.html


Configuring ``CommonNameToSANDefault``
--------------------------------------

If you have Dogtag 10.4, here is how to configure a profile to use
the ``CommonNameToSANDefault``.  Add the following policy directives
(the ``policyset`` and ``serverCertSet`` and index ``12`` are
indicative only, but the index must not collide with other profile
components)::

  policyset.serverCertSet.12.constraint.class_id=noConstraintImpl
  policyset.serverCertSet.12.constraint.name=No Constraint
  policyset.serverCertSet.12.default.class_id=commonNameToSANDefaultImpl
  policyset.serverCertSet.12.default.name=Copy Common Name to Subject

Add the index to the list of profile policies::

  policyset.serverCertSet.list=1,2,3,4,5,6,7,8,9,10,11,12

Then import the modified profile configuration, and you are good to
go.  There are a few minor caveats to be aware of:

- Names containing wildcards are not recognised as DNS names.  The
  rationale is twofold; wildcard DNS names, although currently
  recognised by most programs, are technically a violation of the
  X.509 specification (RFC 5280), and they are `discouraged by RFC
  6125`_.  Therefore if the CN contains a wildcard DNS name,
  ``CommonNameToSANDefault`` will not copy it to the SAN extension.

- Single-label DNS names are not copied.  It is unlikely that people
  will use Dogtag to issue certificates for top-level domains.  If
  ``CommonNameToSANDefault`` encounters a single-label DNS name, it
  will assume it is actually not a DNS name at all, and will not
  copy it to the SAN extension.

- The ``CommonNameToSANDefault`` policy index must come after
  ``UserExtensionDefault``, ``SubjectAltNameExtDefault``, or any
  other component that adds the SAN extension, otherwise an error
  may occur because the older components do not gracefully handle
  the situation where the SAN extension is already present.

.. _discouraged by RFC 6125: https://tools.ietf.org/html/rfc6125#section-7.2


What we are doing in FreeIPA
----------------------------

Updating FreeIPA profiles to use ``CommonNameToSANDefault`` is
trickier - FreeIPA configures Dogtag to use LDAP-based profile
storage, and mixed-version topologies are possible, so updating a
profile to use the new component could break certificate requests on
other CA replicas if they are not all at the new versions.  We do
not want this situation to occur.

The long-term fix is to develop a general, version-aware profile
update mechanism that will import the best version of a profile
supported by all CA replicas in the topology.  I will be starting
this effort soon.  When it is in place we will be able to safely
update the FreeIPA-defined profiles in existing deployments.

In the meantime, we will bump the Dogtag dependency and update the
default profile **for new installations only** in the **4.5.3**
point release.  This will be safe to do because you can only install
replicas at the same or newer versions of FreeIPA, and it will avoid
the CN validation problems for all new installations.


Conclusion
----------

In this post we looked at the technical reasons for deprecating and
removing support for CN domain validation in X.509 certificates, and
discussed the implications of this finally happening, namely: none
for the public CA world, but big problems for some private PKIs and
programs including FreeIPA and Dogtag.  We looked at the new
``CommonNameToSANDefault`` component in Dogtag that makes it easier
to produce compliant certs even when the tools to generate the CSR
don't help you much, and discussed upcoming and proposed changes in
FreeIPA to improve the situation there.

One big takeaway from this is to be more proactive in dealing with
deprecated features in standards, APIs or programs.  It is easy to
punt on the work, saying *"well yes it is deprecated but all the
programs still support it..."*  The thing is, tomorrow they may not
support it anymore, and when it was deprecated for good reasons you
really cannot lay the blame at Google (or whoever).  On the FreeIPA
team we (and especially me as *PKI wonk in residence*) were aware of
these issues but kept putting off the work.  Then one day users and
customers start having problems accessing their internal services in
Chrome!  15 years should have been enough time to deal with it...
but we (I) did not.

Lesson learned.

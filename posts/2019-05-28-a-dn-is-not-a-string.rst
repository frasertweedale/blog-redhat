---
tags: asn1, ldap, certificates
---

A Distinguished Name is not a string
====================================

*Distinguished Names (DNs)* are used to identify entities in LDAP
databases and X.509 certificates.  Although DNs are often presented
as strings, they have a complex structure.  Because of the numerous
formal and ad-hoc serialisations have been devised, and the
prevalence of ad-hoc or buggy parsers, treating DNs as string in the
interals of a program inevitably leads to errors.  In fact,
dangerous security issues can arise!

In this post I will explain the structure of DNs, review the common
serialisation regimes, and review some DN-related bugs in projects I
worked on.  I'll conclude with my *best practices* recommendations
for working with DNs.


DN structure
------------

DNs are defined by the ITU-T **X.501** standard a ASN.1 objects::

  Name ::= CHOICE {
    -- only one possibility for now --
    rdnSequence RDNSequence }

  RDNSequence ::= SEQUENCE OF RelativeDistinguishedName

  DistinguishedName ::= RDNSequence

  RelativeDistinguishedName ::=
    SET SIZE (1..MAX) OF AttributeTypeAndValue

  AttributeTypeAndValue ::= SEQUENCE {
    type  ATTRIBUTE.&id({SupportedAttributes}),
    value ATTRIBUTE.&Type({SupportedAttributes}{@type}),
    ... }

The ``AttributeTypeAndValue`` definition refers to some other
definitions.  It means that ``type`` is an *object identifier (OID)*
of some supported attribute, and the syntax of ``value`` is
determined by ``type``.  The term *attribute-value assertion (AVA)*
is a common synonym for ``AttributeTypeAndValue``.

Applications define a bounded set of supported attributes.  For
example the X.509 certificate standard suggests a minimal set of
supported attributes, and an LDAP server's schema defines all the
attribute types understood by that server.  Depending on the
application, a program might fail to process a DN with an
unrecognised attribute type, or it might process it just fine,
treating the corresponding value as opaque data.

Whereas the order of AVAs within an RDN is insignificant (it is a
``SET``), the order of RDNs within the DN is significant.  If you
view the list left-to-right, then the *root* is on the left.  X.501
formalises it thus:

  Each initial sub-sequence of the name of an object is also the
  name of an object. The sequence of objects so identified, starting
  with the root and ending with the object being named, is such that
  each is the immediate superior of that which follows it in the
  sequence.

This also means that the empty DN is a valid datum.


Comparing DNs
-------------

Testing DNs for equality is an important operation.  For example,
when constructing an X.509 certification path, we have to find a
trusted CA certificate based on the certificate chain presented by
an entity (e.g. a TLS server), then verify that the chain is
complete by ensuring that each *Issuer DN*, starting from the end
entity certificate, matches the *Subject DN* of the certificate
"above" it, all the way up to a trusted CA certificate.  (Then the
signatures must be verified, and several more checks performed).

Continuing with this example, if an implementation falsely
determines that two equal DNs (under X.500) are inequal, then it
will fail to construct the certification path and reject the
certificate.  This is not good.  But even worse would be if it
decides that two unequal DNs are in fact equal!  Similarly, if you
are issuing certificates or creating LDAP objects or anything else,
a user could exploit bugs in your DN handling code to cause you to
issue certificates, or create objects, that you did not intend.

Having motivated the importance of correct DN comparison, well, how
*do* you compare DNs correctly?

First, the program must represent the DNs according to their true
structure: a list of sets (*RDNs*) of attribute-value pairs
(*AVAs*).  If the DNs are not already represented this way in the
program, they must be parsed or processed—correctly.

Now that the structure is correct, AVAs can be compared for
equality.  Each attribute type defines an *equality matching rule*
that says how values should be compared.  In some cases this is just
binary matching.  In other cases, normalisation or other rules must
be applied to the values.  For example, some string types may be
case insensitive.

A notable case is the ``DirectoryString`` syntax used by several
attribute types in X.509::

  DirectoryString ::= CHOICE {
      teletexString       TeletexString   (SIZE (1..MAX)),
      printableString     PrintableString (SIZE (1..MAX)),
      universalString     UniversalString (SIZE (1..MAX)),
      utf8String          UTF8String      (SIZE (1..MAX)),
      bmpString           BMPString       (SIZE (1..MAX)) }

``DirectoryString`` supports a choice of string encodings.  Values
of use ``PrintableString`` orr ``UTF8String`` encoding must be
preprocessed using the LDAP *Internationalized String Preparation*
rules (`RFC 4518`_), including case folding and insignificant
whitespace compression.

.. _RFC 4518: https://tools.ietf.org/html/rfc4518

Taking the DN as a whole, two DNs are equal if they have the same
RDNs in the same order, and two RDNs are equal if they have the same
AVAs in *any* order (i.e. sets of equal size, with each AVA in one
set having a matching AVA in the other set).

Ultimately this means that, despite X.509 certificates using
*Distinguised Encoding Rules (DER)* for serialisation, there can
still be multiple ways to represent equivalent data (by using
different string encodings).  Therefore, binary matching of
serialised DNs, or even binary matching of individual attribute
values, is incorrect behaviour and may lead to failures.


String representations
----------------------

Several string representations of DNs, both formally-specified and
ad-hoc, are in widespread use.  In this section I'll list some of
the more important ones.

Because DNs are ordered, one of the most obvious characteristics of
a string representation is whether it lists the RDNs in *forward* or
*reverse* order, i.e. with the root at the left or right.  Some
popular libraries and programs differ in this regard.

As we look at some of these common implementations, we'll use the
following DN as an example::

  SEQUENCE (3 elem)
    SET (2 elem)
      SEQUENCE (2 elem)
        OBJECT IDENTIFIER 2.5.4.6 countryName
        PrintableString AU
      SEQUENCE (2 elem)
        OBJECT IDENTIFIER 2.5.4.8 stateOrProvinceName
        PrintableString Queensland
    SET (1 elem)
      SEQUENCE (2 elem)
        OBJECT IDENTIFIER 2.5.4.10 organizationName
        PrintableString Acme, Inc.
    SET (1 elem)
      SEQUENCE (2 elem)
        OBJECT IDENTIFIER 2.5.4.3 commonName
        PrintableString CA

RFC 4514
^^^^^^^^

::

  CN=CA,O=Acme\, Inc.,C=AU+ST=Queensland
  CN=CA,O=Acme\2C Inc.,C=AU+ST=Queensland

`RFC 4514`_ defines the string representation of distinguished names
used in LDAP.  As such, there is widespread library support for
parsing and printing DNs in this format.  The RDNs are in reverse
order, separated by ``,``.  Special characters are escaped using
backslash (``\``), and can be represented using the escaped
character itself (e.g. ``\,``) or two hex nibbles (``\2C``).
Alternatively, values containing special characters can be enclosed
in quotes.  There is a way to represent binary attribute values.
The AVAs within a multi-valued RDN are separated by ``+``, in any
order.

Due to the multiple ways of escaping special characters, this is not
a distinguished encoding.

This format is used by GnuTLS, OpenLDAP and FreeIPA, among other
projects.

.. _RFC 4514: https://tools.ietf.org/html/rfc4514


RFC 1485
^^^^^^^^

::

  CN=CA,O="Acme, Inc.",C=AU+ST=Queensland

`RFC 1485`_ is a predecessor of a predecessor (RFC 1779) of a
predecessor (RFC 2253) of RFC 4514.  There are some differences from
RFC 4514.  For example, special character escapes are not supported;
quotes must be used.  This format is still relevant today because
NSS uses it for pretty-printing or parsing DNs.

.. _RFC 1485: https://tools.ietf.org/html/rfc1485


OpenSSL
^^^^^^^

OpenSSL prints DNs in its own special way.  Unlike most other
implementations, it works with DNs in *forward* order (root at
left).  The pretty print looks like::

  C = AU + ST = Queensland, O = "Acme, Inc.", CN = CA

The format when parsing is different again.  Some commands need a
flag to enable support for multi-valued RDNs; e.g.  ``openssl req
-multivalue-rdn ...``.

::

  /C=AU+ST=Queensland/O=Acme, Inc./CN=CA

OpenSSL can also read DNs from a config file where AVAs are given
line by line (see ``config`` and ``x509v3_config(5)``).  But this is
not a DN string representation *per se* so I won't cover it here.


Bugs, bugs, bugs
----------------

Here are three interesting bugs I discovered, related to DN string
encoding.

389 DS `#49543`_: certmap fails when Issuer DN has comma in name
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

.. _#49543: https://pagure.io/389-ds-base/issue/49543

389 DS supports TLS certificate authentication for binding to LDAP.
Different certificate mapping (*certmap*) policies can be defined
for different CAs.  The issuer DN in the client certificate is used
to look up a certmap configuration.  Unfortunately, a string
comparison was used to perform this lookup.  389 uses NSS, which
serialised the DN using RFC 1485 syntax.  If this disagreed with how
the DN in the certmap configuration appeared (after normalisation),
the lookup—hence the LDAP bind—would fail.  The normalisation
function was also buggy.

The `fix
<https://pagure.io/389-ds-base/pull-request/49611#request_diff>`_
was to parse the certmap DN string into an a NSS ``CertNAME``, and
compare the Issuer DN from the certificate against it using the NSS
DN comparison routine (``CERT_AsciiToName``).  The buggy
normalisation routine was deleted.


Certmonger `#90`_: incorrect DN in CSR
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

.. _#90: https://pagure.io/certmonger/issue/90

Certmonger stores tracking request configuration in a flat text
file.  This configuration includes the string representation of the
DN, ostensibly in RFC 4514 syntax.  When constructing a CSR for the
tracking request, it parsed the DN then used the result to construct
an OpenSSL ``X509_NAME``, which would be used in OpenSSL routines to
create the CSR.

Unfortunately, the DN parsing implementation—a custom routine in
Certmonger itself—was busted.  A DN string like::

  CN=IPA RA,O=Acme\, Inc.,ST=Massachusetts,C=US

Resulted in a CSR with the following DN::

  CN=IPA RA,CN=Inc.,O=Acme\\,ST=Massachusetts,C=US

The `fix
<https://pagure.io/certmonger/pull-request/108#request_diff>`_ was
to remove the buggy parser and use the OpenLDAP ``ldap_str2dn``
routine instead.  This was a joint effort between Rob Crittenden and
myself.


FreeIPA `#7750`_: invalid modlist when attribute encoding can vary
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

.. _#7750: https://pagure.io/freeipa/issue/7750

FreeIPA's LDAP library, *ipaldap*, uses *python-ldap* for handling
low-level stuff and provides a lot of useful stuff on top.  One
useful thing it does is keeps track of the original attribute values
for an object, so that we can perform changes locally and
efficiently produce a list of modifications (*modlist*) for when we
want to update the object at the server.

*ipaldap* did not take into account the possibility of the attribute
encoding returned by *python-ldap* differing from the attribute
encoding produced by FreeIPA.  A disagreement could arise when DN
attribute values contained special characters requiring escaping.
For example, *python-ldap* escaped characters using hex encoding::

  CN=CA,O=Red Hat\2C Inc.,L=Brisbane,C=AU

The representation produced by *python-ldap* is recorded as the
original value of the attribute.  However, if you wrote the same
attribute value back, it would pass through FreeIPA's encoding
routine, which might encode it differently and record it as a new
value::

  CN=CA,O=Red Hat\, Inc.,L=Brisbane,C=AU

When you go to update the object, the modlist would look like::

  [ (ldap.MOD_ADD, 'ipacaissuerdn',
      [b'CN=CA,O=Red Hat\, Inc.,L=Brisbane,C=AU'])
  , (ldap.MOD_DELETE, 'ipacaissuerdn',
      [b'CN=CA,O=Red Hat\2C Inc.,L=Brisbane,C=AU'])
  ]

Though encoded differently, *these are the same value* but that in
itself is not a problem.  The problem is that the server also has
the same value, and processing the ``MOD_ADD`` first results in an
``attributeOrValueExists`` error.  You can't add a value that's
already there!

The ideal fix for this would be to update *ipaldap* to record all
values as ASN.1 data or DER, rather than strings.  But that would be
a large and risky change.  Instead, we `work around`_ the issue by
always putting deletes before adds in the modlist.  LDAP servers
process changes in the order they are presented (389 DS does so
atomically).  So deleting an attribute value then adding it straight
back is a safe, albeit inefficient, workaround.

.. _work around: https://github.com/freeipa/freeipa/pull/2511


Discussion
---------------

So you have to compare or handle some DNs.  What do you do?  My
recommendations are:

- If you need to print/parse DNs as strings, if possible use RFC
  4514 because it has the most widespread library support.

- Don't write your own DN parsing code.  This is where security
  vulnerabilities are most likely.  Use existing library routines
  for parsing DNs.  If you have no other choice, take extreme care
  and if possible use a parser combinator library or parser
  generator to make the definitions more declarative and reduce
  likelihood of error.

- Always decode attribute values (if the DN parsing routine doesn't
  do it for you).  This avoids confusion where attribute values
  could be encoded in different ways (due to escaped characters or
  differing string encodings).

- Use established library routines for comparing DNs *using the
  internal DN structures, not strings*.

Above all, just remember: *a Distinguished Name is not a string*, so
don't treat it like a string.  For sure it's more work, but DNs need
special treatment or bugs will certainly arise.

That's not to say that "native" DN parsing and comparison routines
are bug-free.  They are not.  A common error is equal DNs comparing
inequal due to differing attribute string encodings (e.g.
``PrintableString`` versus ``UTF8String``).  I have written about
this in a `previous post`_.  In Dogtag we've enountered this kind of
bug quite_ a_ few_ times.  In these situations the DN comparison
should be fixed, but it may be a satisfactory workaround to
serialise *both* DNs and perform a string comparison.

.. _previous post: 2018-03-15-x509-dn-attribute-encoding.html
.. _quite: https://pagure.io/dogtagpki/issue/2475
.. _a: https://pagure.io/dogtagpki/issue/2828
.. _few: https://pagure.io/dogtagpki/issue/2865

Another common issue is lack of support for multi-valued RDNs.  A
few years ago we wanted to switch FreeIPA's certificate handling
from *python-nss* to the *cryptography* library.  I had to `add
support`_ for multi-valued RDNs before we could make the switch.

.. _add support: https://github.com/pyca/cryptography/issues/3199

A final takeaway for authors of standards.  Providing multiple ways
to serialise the same value leads to incompatibilities and bugs.
For sure, there is a tradeoff between usability, implementation
complexity and risk of interoperability issues and bugs.  RFC 4514
would be less human-friendly if it only permitted hex-escapes.  But
implementations would be simpler and the interop/bug risk would be
reduced.  It's important to think about these tradeoffs and the
consequences, especially for standards and protocols relating to
security.

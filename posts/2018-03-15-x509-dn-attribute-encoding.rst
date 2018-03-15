DN attribute value encoding in X.509
====================================

X.509 certificates use the X.500 *Distinguished Name (DN)* data type
to represent issuer and subject names.  X.500 names may contain a
variety of fields including *CommonName*, *OrganizationName*,
*Country* and so on.  This post discusses how these values are
encoded and compared, and problematic circumstances that can arise.

ASN.1 string types and encodings
--------------------------------

ASN.1 offers a large number of string types, including:

- ``NumericString``
- ``PrintableString``
- ``IA5String``
- ``UTF8String``
- ``BMPString``
- …several others

When serialising an ASN.1 object, each of these string types has a
different tag.  Some of the types have a shared representation for
serialisation but differ in which characters they allow.  For
example, ``NumericString`` and ``PrintableString`` are both
represented in DER using one byte per character.  But
``NumericString`` only allows digits (``0``–``9``) and ``SPACE``,
whereas ``PrintableString`` admits the full set of ASCII printable
characters.  In contrast, ``BMPString`` uses two bytes to represent
each character; it is equivalent to UTF-16BE.  ``UTF8String``,
unsurprisingly, uses UTF-8.

ASN.1 string types for X.509 name attributes
--------------------------------------------

Each of the various X.509 name attribute types uses a specific ASN.1
string type.  Some types have a size constraint.  For example::

  X520countryName      ::= PrintableString (SIZE (2))
  DomainComponent      ::= IA5String
  X520CommonName       ::= DirectoryName (SIZE (1..64))
  X520OrganizationName ::= DirectoryName (SIZE (1..64))

Hold on, what is ``DirectoryName``?  It is not a universal ASN.1
type; it is specified as a sum of string types::

  DirectoryName ::= CHOICE {
      teletexString     TeletexString,
      printableString   PrintableString,
      universalString   UniversalString,
      utf8String        UTF8String,
      bmpString         BMPString }

Note that a size constraint on ``DirectoryName`` propagates to each
of the cases.  The constraint gives a maximum length in
*characters*, not bytes.

Most X.509 attribute types use ``DirectoryName``, including *common
name (CN)*, *organization name (O)*, *organizational unit (OU)*,
*locality (L)*, *state or province name (ST)*.  For these attribute
types, which encoding should be used?  `RFC 5280 §4.1.2.6`_ provides
some guidance:

.. _RFC 5280 §4.1.2.4: https://tools.ietf.org/html/rfc5280#section-4.1.2.4

::

   The DirectoryString type is defined as a choice of PrintableString,
   TeletexString, BMPString, UTF8String, and UniversalString.  CAs
   conforming to this profile MUST use either the PrintableString or
   UTF8String encoding of DirectoryString, with two exceptions.

The current version of X.509 only allows ``PrintableString`` and
``UTF8String``.  Earlier versions allowed any of the types in
``DirectoryString``.  The *exceptions* mentioned are grandfather
clauses that permit the use of the now-prohibited types in
environments that were already using them.

So for strings containing non-ASCII code points ``UTF8String`` is
the only type you can use.  But for ASCII-only strings, there is
still a choice, and the RFC does not make a recommendation on which
to use.  Both are common in practice.

This poses an interesting question.  Suppose two encoded DNs have
the same attributes in the same order, but differ in the string
encodings used.  Are they the same DN?


Comparing DNs
-------------

`RFC 5280 §7.1`_ outlines the procedure for comparing DNs.  To
compare strings you must convert them to Unicode, translate or drop
some special-purpose characters, and perform case folding and
normalisation.  The resulting strings are then compared
case-insensitively.  According to this rule, DNs that use different
string encodings but are otherwise the same are **equal**.

.. _RFC 5280 §7.1: https://tools.ietf.org/html/rfc5280#section-7.1

But the situation is more complex in practice.  Earlier versions of
X.509 required only binary comparison of DNs.  For example, `RFC
3280`_ states:

.. _RFC 3280: https://tools.ietf.org/html/rfc3280

::

   Conforming implementations are REQUIRED to implement the following
   name comparison rules:

      (a)  attribute values encoded in different types (e.g.,
      PrintableString and BMPString) MAY be assumed to represent
      different strings;

      (b) attribute values in types other than PrintableString are case
      sensitive (this permits matching of attribute values as binary
      objects);

      (c)  attribute values in PrintableString are not case sensitive
      (e.g., "Marianne Swanson" is the same as "MARIANNE SWANSON"); and

      (d)  attribute values in PrintableString are compared after
      removing leading and trailing white space and converting internal
      substrings of one or more consecutive white space characters to a
      single space.

Futhermore, RFC 5280 and earlier versions of X.509 state::

   The X.500 series of specifications defines rules for comparing
   distinguished names that require comparison of strings without regard
   to case, character set, multi-character white space substring, or
   leading and trailing white space.  This specification relaxes these
   requirements, requiring support for binary comparison at a minimum.

This is a contradiction.  The above states that binary comparison of
DNs is acceptable, but other sections require a more sophisticated
comparison algorithm.  The combination of this contradiction,
historical considerations and (no doubt) programmer laziness means
that many X.509 implementations only perform **binary comparison**
of DNs.


How CAs should handle DN attribute encoding
-------------------------------------------

To ease certification path construction with clients that only
perform binary matching of DNs, RFC 5280 states the following
requirement::

  When the subject of the certificate is a CA, the subject
  field MUST be encoded in the same way as it is encoded in the
  issuer field (Section 4.1.2.4) in all certificates issued by
  the subject CA.  Thus, if the subject CA encodes attributes
  in the issuer fields of certificates that it issues using the
  TeletexString, BMPString, or UniversalString encodings, then
  the subject field of certificates issued to that CA MUST use
  the same encoding.

This is confusing wording, but in practical terms there are two
requirements:

1. The Issuer DN on a certificate must be byte-identical to the
   Subject DN of the CA that issued it.

2. The attribute encodings in a CA's Subject DN must not change
   (e.g.  when the CA certificate gets renewed).

If a CA violates either of these requirements breakage will ensue.
Programs that do binary DN comparison will be unable to construct a
certification path to the CA.

For *end-entity* (or *leaf*) certificates, the subject DN is not use
in any links of the certification path.  Changing the subject
attribute encoding when renewing an end-entity certificate will not
break validation.  But it could still confuse some programs that
only do binary comparison of DNs (e.g. they might display two
distinct subjects).


Processing certificate requests
-------------------------------

What about when processing certificate requests—should CAs respect
the attribute encodings in the CSR?  In my experience, CA programs
are prone to issuing certificates with the subject encoded
differently from how it was encoded in the CSR.  CAs may do various
kinds of validation, substitution or addition of subject name
attributes.  Or they may enforce the use of a particular encoding
regardless of the encoding in the CSR.

Is this a problem?  It depends on the client program.  In my
experience most programs can handle this situation.  Problems mainly
arise when the issuer or subject encoding changes *upon renewal*
(for the reasons discussed above).

If a CSR-versus-certificate encoding mismatch does cause a problem
for you, you may have to create a new CSR with the attributes
encoding you expect the CA to use for the certificate.  In many
programs this is not straightforward, if it is possible at all.  If
you control the CA you might be able to configure it to use
particular encodings for string attributes, or to respect the
encodings in the CSR.  The options available and how to configure
them vary among CA programs.


Recap
-----

X.509 requires the use of either ``PrintableString`` or
``UTF8String`` for most DN attribute types.  Strings consisting of
printable 7-bit ASCII characters can be represented using either
encoding.  This ambiguity can lead to problems in certification path
construction.

Formally, two DNs that have the same attributes and values are the
same DN, regardless of the string encodings used.  But there are
many programs that only perform binary matching of DNs.  To avoid
causing problems for such programs a CA:

- *must* ensure that the Issuer DN field on all certificates it issues
  is identical to its own Subject DN;

- *must* ensure that Subject DN attribute encodings on CA certificates
  it issues to a given subject do not change upon renewal;

- *should* ensure that Subject DN attribute encodings on end-entity
  certificates it issues to a given subject do not change upon
  renewal.

CAs will often issue certificates with values encoded differently
from how they were presented in the CSR.  This usually does not
cause problems.  But if it does cause problems, you might be able to
configure the client program to produce a CSR with different
attribute encodings.  If you control the CA you may be able to
configure it to have a different treatment for attribute encodings.
How to do these things was beyond the scope of this article.

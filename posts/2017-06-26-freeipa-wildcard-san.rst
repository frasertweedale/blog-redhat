Wildcard SAN certificates in FreeIPA
====================================

In `an earlier post`_ I discussed how to make a certificate profile
for wildcard certificates in FreeIPA, where the wildcard name
appeared in the *Subject Common Name (CN)* (but not the *Subject
Alternative Name (SAN)* extension).  Apart from the technical
details that post also explained that wildcard certificates are
deprecated, *why* they are deprecated, and therefore why I was not
particularly interested in pursuing a way to get wildcard DNS names
into the SAN extension.

But, as was portended long ago (more than 15 years, when `RFC 2818`_
was published) DNS name assertions via the CN field are deprecated,
and finally some client software removed CN name processing support.
The Chrome browser is first off the rank, but it won't be the last!

Unfortunately, programs that have typically used wildcard
certificates (hosting services/platforms, PaaS, and sites with many
subdomains) are mostly still using wildcard certificates, and
FreeIPA still needs to support these programs.  As much as I would
like to say "just use *Let's Encrypt* / ACME!", it is not realistic
for all of these programs to update in so short a time.  Some may
never be updated.  So for now, wildcard DNS names in SAN is more
than a "nice to have" - it is a **requirement** for a handful of
valid use cases.


Configuration
-------------

Here is how to do it in FreeIPA.  Most of the steps are the same as
in `the earlier post`_ so I will not repeat them here.  The only
substantive difference is in the Dogtag profile configuration.

In the profile configuration, set the following directives (note
that the key ``serverCertSet`` and the index ``12`` are indicative
only; the index does not matter as long as it is different from the
other profile policy components)::

  policyset.serverCertSet.12.constraint.class_id=noConstraintImpl
  policyset.serverCertSet.12.constraint.name=No Constraint
  policyset.serverCertSet.12.default.class_id=subjectAltNameExtDefaultImpl
  policyset.serverCertSet.12.default.name=Subject Alternative Name Extension Default
  policyset.serverCertSet.12.default.params.subjAltNameNumGNs=2
  policyset.serverCertSet.12.default.params.subjAltExtGNEnable_0=true
  policyset.serverCertSet.12.default.params.subjAltExtType_0=DNSName
  policyset.serverCertSet.12.default.params.subjAltExtPattern_0=*.$request.req_subject_name.cn$
  policyset.serverCertSet.12.default.params.subjAltExtGNEnable_1=true
  policyset.serverCertSet.12.default.params.subjAltExtType_1=DNSName
  policyset.serverCertSet.12.default.params.subjAltExtPattern_1=$request.req_subject_name.cn$

Also be sure to add the index to the directive containing the list
of profile policies::

  policyset.serverCertSet.list=1,2,3,4,5,6,7,8,9,10,11,12

This configuration will cause two SAN DNSName values to be added to
the certificate - one using the CN from the CSR, and the other using
the CN from the CSR preceded by a wildcard label.

Finally, be aware that because the ``subjectAltNameExtDefaultImpl``
component adds the SAN extension to a certificate, it conflicts with
the ``userExtensionDefault`` component when configured to copy the
SAN extension from a CSR to the new certificate.  This profile
component will have a configuration like the following::

  policyset.serverCertSet.11.constraint.class_id=noConstraintImpl
  policyset.serverCertSet.11.constraint.name=No Constraint
  policyset.serverCertSet.11.default.class_id=userExtensionDefaultImpl
  policyset.serverCertSet.11.default.name=User Supplied Extension Default
  policyset.serverCertSet.11.default.params.userExtOID=2.5.29.17

Again the numerical index is indicative only, but the OID is not;
``2.5.29.17`` is the OID for the SAN extension.  If your starting
profile configuration contains the same directives, **remove them**
from the configuration, and remove the index from the policy list
too::

  policyset.serverCertSet.list=1,2,3,4,5,6,7,8,9,10,12

Discussion
----------

The profile containing the configuration outlined above will issue
certificates with a wildcard DNS name in the SAN extension,
alongside the DNS name from the CN.  Mission accomplished; but note
the following caveats.

This configuration cannot contain the ``userExtensionDefaultImpl``
component, which copies the SAN extension from the CSR to the final
certificate if present in the CSR, because any CSR that contains a
SAN extension would cause Dogtag to attempt to add a second SAN
extension to the certificate (this is an error).  It would be better
if the conflicting profile components somehow "merged" the SAN
values, but this is not their current behaviour.

Because we are not copying the SAN extension from the CSR, any SAN
extension in the CSR get ignored by Dogtag - *but not by FreeIPA*;
the FreeIPA CSR validation machinery always fully validates the
subject alternative names it sees in a CSR, regardless of the Dogtag
profile configuration.

If you work on software or services that currently use wildcard
certificates please start planning to move away from this.  CN
validation was deprecated for a long time and is finally being
phased out; **wildcard certificates are also deprecated** (`RFC
6125`_) and they too may eventually be phased out.  Look at services
and technologies like *Let's Encrypt* (a free, automated, publicly
trusted CA) and *ACME* (the protocol that powers it) for acquiring
all the certificates you need without administrator or operator
intervention.

.. _an earlier post: 2017-02-20-freeipa-wildcard-certs.html
.. _the earlier post: 2017-02-20-freeipa-wildcard-certs.html
.. _RFC 2818: https://tools.ietf.org/html/rfc2818
.. _RFC 6125: https://tools.ietf.org/html/rfc6125#section-7.2

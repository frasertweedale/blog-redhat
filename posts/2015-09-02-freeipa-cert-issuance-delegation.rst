Delegating certifiate issuance in FreeIPA
=========================================

`FreeIPA 4.2`_ brings several certificate management improvements
including custom profiles and user certificates.  Along with the
explosion in certificate use cases that are now support comes the
question of how to manage certificate issuance, along two
dimensions: which entities can be issued what kinds of certificates,
and who can actually request a certificate?  The first aspect is
managed via CA ACLs, which were `explained in a previous article`_.
In this post I detail how FreeIPA decides whether a requesting
principal is allowed to request a certificate for the subject
principal, and how to delegate the authority to issue certificates.

.. _FreeIPA 4.2: http://www.freeipa.org/page/Releases/4.2.0
.. _explained in a previous article: 2015-08-06-freeipa-custom-certprofile.html


Self-service requests
---------------------

The simplest scenario is a principal using ``cert-request`` to
request a certificate for itself as the certificate subject.  This
action is permitted for user and host principals but the request is
**still subject to CA ACLs**; if no CA ACL permits issuance for the
combination of subject principal and certificate profile, the
request will fail.

Implementation-wise, self-service works because there are directory
server ACIs that permit bound principals to modify their own
``userCertificate`` attribute; there is no explicit permission
object.


Hosts
-----

Hosts may request certificates for any hosts and services that are
*managed by* the requesting host.  These relationships are managed
via the ``ipa host-{add,remove}-managedby`` commands, and a single
host or service may be managed by multiple hosts.

This rule is implemented using directory server ACIs that allow
hosts to write the ``userCertificate`` attribute when the
``managedby`` relationship exists, otherwise not.  In the IPA
framework, we conduct a permission check to see if the bound
(requesting) principal can write the subject principal's attribute.
This is nicer (and probably faster) than interpreting the
``managedby`` attribute in the FreeIPA framework.

If you are interested, the ACI rules look like this::

  dn: cn=services,cn=accounts,$SUFFIX
  aci: (targetattr="userCertificate || krbPrincipalKey")(version 3.0;
        acl "Hosts can manage service Certificates and kerberos keys";
        allow(write) userattr = "parent[0,1].managedby#USERDN";)

  dn: cn=computers,cn=accounts,$SUFFIX
  aci: (targetattr="userCertificate || krbPrincipalKey")(version 3.0;
        acl "Hosts can manage other host Certificates and kerberos keys";
        allow(write) userattr = "parent[0,1].managedby#USERDN";)

As usual, these requests are also subject to CA ACLs.

Finally, *subjectAltName* *dNSName* values are matched against hosts
(if the subject principal is a host) or services (if it's a
service); they are treated as additional subject principals and the
same permission and CA ACL checks are carried out for each.


Users
-----

FreeIPA's *Role Based Access Control* (RBAC) system is used to
assign certificate issuance permissions to users (or other principal
types).  There are several permissions related to certificate
management:

*Request Certificate*
  The main permission that allows a user to request certificates for
  other principals.

*Request Certificate with SubjectAltName*
  This permission allows a user (one who already has *Request
  Certificate* permission) to request a certificate with the
  *subjectAltName* extension (the check is skipped when the request
  is self-service or initated by a host principal).  Regardless of
  this permission we comprehensively validate the SAN extension
  whenever present in a CSR (and always have), so I'm not sure why
  this exists as a separate permission.  I proposed to remove this
  permission and allow SAN by default but the conversation died.

*Request Certificate ignoring CA ACLs* (new in FreeIPA 4.2)
  The main use case for this permission is where a certain profile
  is not appropriate for self-service.  For example, if you want to
  issue certificates bearing some estoeric or custom extension
  unknown to (and therefore not validatable by) FreeIPA, you can
  define a profile that copies the extension data verbatim from the
  CSR.  Such a profile ought not be made available for self-service
  via CA ACLs, but this permission will allow a privileged user to
  issue the certificates on behalf of others.

*System: Manage User Certificates* (new in FreeIPA 4.2.1)
  Permits writing the ``userCertificate`` attribute of user entries.

*System: Manage Host Certificates*
  Permits writing the ``userCertificate`` attribute of host entries.

*System: Modify Services*
  Permits writing the ``userCertificate`` attribute of service entries.

There are other permissions related to revocation and retrieving
certificate information from the Dogtag CA.  It might make sense for
certificate administrators to have some of these permissions but
they are not needed for issuance and I will not detail them here.

The RBAC system is used to group *permissions* into *privileges* and
privileges into *roles*.  Users, user groups, hosts, host groups and
services can then be assigned to a role.  Let's walk through an
example: we want members of the ``user-cert-managers`` group to be
able to issue certificates for users.  The SAN extension will be
allowed, but CA ACLs may not be bypassed.

It bears mention that there is a default privilege called
*Certificate Administrators* that contains most of the certificate
management permissions; for this example we will create a new
privilege that contains *only* the required permissions.  We will
use the ``ipa`` CLI program to implement this scenario, but it can
also be done using the web UI.  Assuming we have a privileged
Kerberos ticket, let's first create a new *privilege* and add to it
the required permissions::

  ftweedal% ipa privilege-add "Issue User Certificate"
  ----------------------------------------
  Added privilege "Issue User Certificate"
  ----------------------------------------
    Privilege name: Issue User Certificate

  ftweedal% ipa privilege-add-permission "Issue User Certificate" \
      --permission "Request Certificate" \
      --permission "Request Certificate with SubjectAltName" \
      --permission "System: Manage User Certificates"
    Privilege name: Issue User Certificate
    Permissions: Request Certificate,
                 Request Certificate with SubjectAltName,
                 System: Manage User Certificates
  -----------------------------
  Number of permissions added 3
  -----------------------------

Next we create a new *role* and add the privilege we just created::

  ftweedal% ipa role-add "User Certificate Manager"
  -------------------------------------
  Added role "User Certificate Manager"
  -------------------------------------
    Role name: User Certificate Manager

  ftweedal% ipa role-add-privilege "User Certificate Manager" \
      --privilege "Issue User Certificate"
    Role name: User Certificate Manager
    Privileges: Issue User Certificate
  ----------------------------
  Number of privileges added 1
  ----------------------------

Finally we add the ``user-cert-managers`` group (which we assume
already exists) to the role::

  ftweedal% ipa role-add-member "User Certificate Manager" \
      --groups user-cert-managers
    Role name: User Certificate Manager
    Member groups: user-cert-managers
    Privileges: Issue User Certificate
  -------------------------
  Number of members added 1
  -------------------------

With that, users who are members of the ``user-cert-managers`` group
will be able to request certificates for all users.


Conclusion
----------

In addition to self-service, FreeIPA offers a couple of ways to
delegate certificate request permissions.  For hosts, the
``managedby`` relationship grants permission to request certificates
for services and other hosts.  For users, RBAC can be used to grant
permission to manage user, host and service principals, even
separately as needs dictate.  In all cases except where the RBAC
*Request Certificate ignoring CA ACLs* permission applies, CA ACLs
are enforced.

Looking ahead, I can see scope for augmenting or complementing CA
ACLs - which currently are concerned with the *subject* or target
principal and care nothing about the *requesting* principal - with a
mechanism to control which principals may *issue* requests involving
a particular profile.  But how much this is wanted we will wait and
see; it is one of many possible improvents to FreeIPA's certificate
management and all will have to be judged according to the demand
and impact.

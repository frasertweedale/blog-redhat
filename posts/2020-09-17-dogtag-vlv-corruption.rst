---
tags: dogtag, ldap, troubleshooting
---

Dogtag, number ranges and VLV indices
=====================================

In a `previous post`_ I explained Dogtag's identifier range
management.  This is how a Dogtag replica knows what range it should
use to assign serial numbers, request IDs, etc.  What that article
did not cover is how Dogtag at startup works out *where it is up to*
in the range.  In this post I explain how uses LDAP *Virtual List
View* to do that, how it can break, and how to fix it.

.. _previous post: 2019-07-26-dogtag-replica-ranges.html

LDAP Virtual List View
----------------------

The LDAP protocol has an optional extension called *Virtual List
View (VLV)*, which is specified in an `expired Internet-Draft`_.
VLV supports result *paging* and is an extension of the *Server Side
Sort (SSS)* control (`RFC 2891`_).  For a search that is covered by
a VLV index, a client can specify a page size and offset and get
just that portion of the result.  It can also seek a specified
attribute value and return nearby results.

.. _expired Internet-Draft: https://datatracker.ietf.org/doc/draft-ietf-ldapext-ldapv3-vlv/
.. _RFC 2891: https://tools.ietf.org/html/rfc2891

In 389DS / RHDS, a VLV index is defined by two objects under
``cn=config``.  One of the VLV indices used in Dogtag is the search
of all certificates sorted by serial number:

.. code:: ldif

  dn: cn=allCerts-pki-tomcat,
      cn=ipaca, cn=ldbm database, cn=plugins, cn=config
  objectClass: top
  objectClass: vlvSearch
  cn: allCerts-pki-tomcat
  vlvBase: ou=certificateRepository,ou=ca,o=ipaca
  vlvScope: 1
  vlvFilter: (certstatus=*)

  dn: cn=allCerts-pki-tomcatIndex, cn=allCerts-pki-tomcat,
      cn=ipaca, cn=ldbm database, cn=plugins, cn=config
  objectClass: top
  objectClass: vlvIndex
  cn: allCerts-pki-tomcatIndex
  vlvSort: serialno
  vlvEnabled: 0
  vlvUses: 0

The first object defines the search base and filter.  When
performing a VLV search, these **must match**.  The second object
declares which attribute is the sort key.  To perform a VLV search
the client must use both the SSS control (which chooses the sort
key) and the VLV control (which selects the page or the value of
interest).

Dogtag range initialisation
---------------------------

When Dogtag is starting up, for each active identifier range it has
to determine the first unused number.  It uses VLV searches to do
this.  For serial numbers, it uses the VLV index shown above.  For
request IDs and other ranges, there are other indices.  The VLV
search targets the upper limit of the range, and requests the
preceding values.  It then looks for the highest value in the result
that is also within the active range.  This is the last number that
was used; we increment it to get the next available number.

To make it a bit more concrete, we can perform a VLV search
ourselves using ``ldapsearch``::

  # ldapsearch -LLL -D "cn=Directory Manager" -w $DM_PASS \
      -b ou=certificateRepository,ou=ca,o=ipaca -s one \
      -E 'sss=serialno' -E 'vlv=1/0:09267911168' \
      '(certStatus=*)' 1.1
  dn: cn=397,ou=certificateRepository,ou=ca,o=ipaca

  dn: cn=267911185,ou=certificateRepository,ou=ca,o=ipaca

  # sortResult: (0) Success
  # vlvResultpos=2 count=177 context= (0) Success

In this search the target value (end of the active range) is
``09267911168``.  This is the integer ``267911168`` preceded by a
two-digit length value.  This is needed because the ``serialno``
attribute has ``Directory String`` syntax, which is sorted
lexicographically.  The ``1/0`` part of the control is asking for
one value preceding the target value, and zero values following it.

The result contains two objects: ``397`` (which precedes the target)
and ``267911185`` (which follows it).  Why did we get a number
following the target value?  The target entry is the first entry
whose sort attribute value is *greater than or equal* the target
value.  In this way, results greater than the target can appear in
the result, as happened here.

The search above relates to the range ``1..267911168``.  The result
shows us to initialise the repository with ``397`` as the "last
used" number.  The next certificate issued by this replica will have
serial number ``398``.

VLV index corruption
--------------------

If a VLV index is corrupt or incomplete, Dogtag could initialise a
repository with a too-low "last used" number.  This could happen for
serial numbers, request IDs or any other kind of managed range.
When that happens, CA operations including certificate issuance or
CSR submission could fail.

In fact, the ``ldapsearch`` above is from a customer case.  A full
search of the ``ou=certificateRepository`` showed thousands of
certificates that were not included in the VLV index.  If CA
operations are failing due to LDAP "Object already exists" errors,
you can perform this check to confirm or rule out VLV index
corruption as the source of the problem.  Keep in mind that VLV
indices are maintained separately on each replica.  Checks have to
be performed on the replica where the problem is occurring.


Rebuilding VLV indices
----------------------

389DS makes it easy to rebuild a VLV index.  You create a *task*
object and the DS takes care of it.  For Dogtag, we even provide a
template LDIF file for a task that reindexes *all* the VLV indices
that Dogtag creates and uses.

First, copy and fill the template::

  $ /bin/cp /usr/share/pki/ca/conf/vlvtasks.ldif .
  $ sed -i "s/{instanceId}/pki-tomcat/g" vlvtasks.ldif
  $ sed -i "s/{database}/ipaca/g" vlvtasks.ldif

Note that ``{database}`` should be replaced with ``ipaca`` in a
FreeIPA instance, but for a standalone Dogtag deployment the correct
value is usually ``ca``.  Now let's look at the LDIF file:

.. code:: ldif

  dn: cn=index1160589769, cn=index, cn=tasks, cn=config
  objectclass: top
  objectclass: extensibleObject
  cn: index1160589769
  ttl: 10
  nsinstance: ipaca
  nsindexVLVAttribute: allCerts-pki-tomcatIndex
  # ... 33 more nsindexVLVAttribute values

The ``cn`` is just a name for the task.  I think you can put
anything here.  ``ttl`` specifies how many seconds 389DS will wait
after the task finishes, before deleting it.

This task object refers to VLV indices in the Dogtag database.  But
you can see all that is needed to rebuild *any* VLV index is the
``nsinstance`` (name of the database) and the
``nsindexVLVAttribute`` (name of a VLV index).

Now we add the object, wait a few seconds, and have a look at it::

  $ ldapadd -x -D "cn=Directory Manager" -w $DM_PASS \
      -f vlvtasks.ldif
  $ sleep 5
  $ ldapsearch -x -D "cn=Directory Manager" -w $DM_PASS \
    -b "cn=index1160589769,cn=index,cn=tasks,cn=config"

.. code:: ldif

  dn: cn=index1160589769,cn=index,cn=tasks,cn=config
  objectClass: top
  objectClass: extensibleObject
  cn: index1160589769
  ttl: 10
  nsinstance: ipaca
  nsindexvlvattribute: allCerts-pki-tomcatIndex
  # .. 33 more nsindexvlvattribute values
  nsTaskCurrentItem: 0
  nsTaskTotalItems: 1
  nsTaskCreated: 20200916021128Z
  nsTaskLog:: aXBhY2E6IEluZGV4aW #... (base64-encoded log)
  nsTaskStatus: ipaca: Finished indexing.
  nsTaskExitCode: 0

We can see that the task finished successfully, and there is some
(truncated) log output if we want more details.  After a few more
seconds, 389DS will delete the object.  You can increase the ``ttl``
if you want to keep the objects for longer.


Discussion
----------

This year I have encountered variations of this problem on several
occasions.  I don't know what the cause(s) are, i.e. why VLV indices
get corrupted or stop updating.  Hopefully DS experts will be able
to shed more light on the issue.

We are considering adding an automated check to the FreeIPA *Health
Check* system, specifically for the range management VLVs.  The
`upstream ticket`_ already contains some discussion and high level
steps of how the check would work.

The proper fix for this issue is to move to UUIDs for all object
identifiers.  Serial numbers might need something different but it
is the same idea.  This work is on the roadmap.  *So many problems*
will go away when we make this change.

.. _upstream ticket: https://github.com/freeipa/freeipa-healthcheck/issues/151

Historical commentary: I don't know why the ``serialno``,
``requestId`` and other attributes use Directory String syntax,
which necessitates the length prefixing hack.  Maybe SSS/VLV only
work on strings (or it was thus in the past).  The code predates our
current VCS and the reasons are lost in time.  The implication of
this is that we can only handle numbers up to 99 decimal digits.
Assumptions like this do bother me, but I think we are probably OK
here.  For my lifetime, anyway.

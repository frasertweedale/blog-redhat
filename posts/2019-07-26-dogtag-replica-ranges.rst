---
tags: dogtag, troubleshooting, internals
---

Dogtag replica range management
===============================

Dogtag supports distributed deployment, with multiple *replicas*
(also called *clones*) processing requests and issuing certificates.
All replicas read and write a replicated LDAP database.  A Dogtag
server can create many kinds of objects: certificates, requests,
archived keys or secrets.  These objects need identifiers that are
unique across the deployment.

How does a Dogtag clone choose an identifier for a new object?  In
this post I will explain Dogtag's *range management*—how it works,
how it can break, and what to do if it does.


Object types with managed ranges
--------------------------------

There are several types of objects for which Dogtag manages
identifier ranges.  For example:

- Certificate serial numbers; it is essential that these be unique.
  Collisions are a violation of X.509 and can lead to erroneous
  **denial of service**, or **false positive** validity, when
  revocation comes into play.

- Certificate requests (including revocation and renewal requests)
  are stored in the database and must have a unique ID.  Clobbering
  of requests objects due to range conflicts can lead to renewal
  request failures resulting in **denial of service**, or worse,
  issuance of a valid certificate with incorrect details, allowing
  **impersonation** attacks.

- KRA request identifiers are assigned from a managed range.

- KRA archived key and data objects are assigned from a managed
  range.

- Clones themselves are assigned identifiers when they are created;
  these come from managed ranges.

The identifiers themselves are unbounded nonzero integers.  All of
the managed ranges are separate domains.  That is, the same numbers
exist in each range, and the ranges are managed independently.


Active and standby ranges
-------------------------

For each kind of range, each replica remembers up to two range
assignments.  The *active* range is the range from which identifiers
are actively assigned.  When the active range is exhausted, the
*standby* range becomes the active range and the clone acquires a
new range assignment, which will be the new standby range.  A clone
doesn't necessarily have a standby range at all times.  It only
acquires a new allocation for the standby range when the unused
amount of its active range falls below some configured *low water
mark*.


Range assignments
-----------------

Range assignments are recorded in LDAP.  A clone's active and
standby ranges are also recorded in the clone's ``CS.cfg``
configuration file.  A range object looks like::

  dn: cn=10000001,ou=certificateRepository,ou=ranges,o=ipaca
  objectClass: top
  objectClass: pkiRange
  beginRange: 10000001
  endRange: 20000000
  cn: 10000001
  host: f30-1.ipa.local
  SecurePort: 443

This is a serial number range assignment.  Host ``f30-1.ipa.local``
has been assigned the range ``10000001..20000000``.  It is not
apparent from this object, but these are actually **hexadecimal**
numbers!  Whether the numbers are decimal or hexadecimal varies
among managed ranges.

The directives in the ``CS.cfg`` on ``f30-1.ipa.local`` reflect this
assignment::

  dbs.enableSerialManagement=true

  dbs.beginSerialNumber=fff0001
  dbs.endSerialNumber=10000000

  dbs.nextBeginSerialNumber=10000001
  dbs.nextEndSerialNumber=20000000

  dbs.enableRandomSerialNumbers=false
  dbs.randomSerialNumberCounter=-1

  dbs.serialCloneTransferNumber=10000
  dbs.serialIncrement=10000000
  dbs.serialLowWaterMark=2000000

The active range is ``fff0001..10000000``, and the standby range is
``10000001..20000000``, which corresponds to the LDAP entry shown
above.

Range delegation
~~~~~~~~~~~~~~~~

Why is ``f30-1``'s active range so much smaller than its standby
range?  This is the result of how ranges are assigned during
cloning.  When creating a clone, the server being configured
contacts an existing clone and asks it for some configuration
values, including serial/request/replica ID ranges.  The existing
clone *delegates* to the new clone a small segment of either its
active or standby range.  It delegates *from the end* of its active
range, but if there are not enough numbers left in the active range,
it delegates from the end the standby range instead.

The size of the range delegation is configured in ``CS.cfg``.  For
example, for serial numbers it is the
``dbs.serialCloneTransferNumber`` setting.  I have never heard of
anyone changing the default, and I can't think of a reason to do so.

Because the delegation is a portion of an already-assigned range
(with corresponding LDAP object), new LDAP range objects are not
created for delegated ranges, and the existing range object is not
modified in any way.  Therefore, LDAP only ever shows the *original*
range assignments.

This range delegation procedure has been a source of bugs.  For
example, `issue 3055`_ was a cloning failure when creating two
clones (call them *C* and *D*) from a server that is itself a clone
(call it *B*).  Because the delegation size is fixed (the
``dbs.serialCloneTransferNumber`` setting), creating *C* delegates
*B*'s whole active range to *C*.  Unless *B* had a chance to switch
to its standby range (when didn't happen during cloning), creating
the second clone *D* would fail because *B*'s active range was
exhausted.  This issue was fixed, but a more robust solution is to
do away with range delegation entirely; the server can create full
range assignments for the new clone instead of delegating part of
its own range assignment.  `Issue 3060`_ tracks this work.

.. _issue 3055: https://pagure.io/dogtagpki/issue/3055
.. _Issue 3060: https://pagure.io/dogtagpki/issue/3060


Random serial numbers
---------------------

Most repositories with range management yield numbers sequentially
from the active ranges.  For the certificate repository only, you
can optionally enable *random* serial numbers.  Numbers are chosen
by a uniform random sample from the clone's assigned range.  Dogtag
checks to make sure the number was not already used; if it was used,
it tries again (and again, up to a limit).

Some additional configuration values come into play when using
random serial numbers:

``dbs.enableRandomSerialNumbers``
  Enable random serial numbers (default: off)
``dbs.collisionRecoverySteps``
  How many retries when a collision is detected (default: 10)
``dbs.minimumRandomBits``
  Minimum size of the range, in bits (default: 4 bits)
``dbs.serialLowWaterMark``
  Switch to standby range when there are fewer than this many
  serials left in the range (default: 2000000)

Critically, The ``dbs.minimumRandomBits`` does *not* determine how
much entry is in the serial number.  If many serial numbers in the
range have already been used, the actual number of serials left
could be less than ``dbs.minimumRandomBits`` of entropy.  When
issuing random serial numbers, the server keeps a running count of
how many serial numbers have been used in the active range.  When
the range size minus the current count falls below
``dbs.serialLowWaterMark``, the server switches to the standby
range.  Therefore it is ``dbs.serialLowWaterMark``, not
``dbs.minimumRandomBits``, that actually controls the minimum amount
of randomness in the serial number.


Switching to the standby range
------------------------------

The actions performed by the subroutine that switches to the next
range are:

1. Set the active range start and end variables to the standby range
  start and end
#. Reset the standby range start and end variables to ``null``
#. Reset counters
#. Persist these changes to ``CS.cfg``.

The switchover procedure **does not acquire a new standby range
assignment**.  Immediately after switching to the standby range,
there isn't a standby range anymore.


Acquiring a new range assignment
---------------------------------

As currently implemented, a new standby range is **only acquired at
system startup**.  Dogtag checks each repository to see if the
amount of unused numbers in the active range has fallen below the
*low water mark*.  If it has, and if there is no standby range, it
self-allocates a new range assignment in LDAP.  The size of the
allocation is determined by ``CS.cfg`` configurables, and its lower
bound is the value of the ``nextRange`` attribute in the repository
parent LDAP object.  It adds a range object to the ranges subtree,
and updates the ``nextRange`` attribute on the repository parent.
See the appendix for a list of which subtree parents and range
entries are involved for each repository.

This procedure is brittle under the possibliity of LDAP replication
races or transient failures.  Two clones could end up adding the
same range, and a replication error will occur.  This can lead to
identifier collisions resulting in problems later (see earlier
discussion).


Internals
---------

Most of everything discussed so far lives in the ``Repository``
class, with ``CertificateRepository`` providing additional behaviour
related to random serial numbers.  Code for acquiring a new range
assignment lives in ``DBSubsystem``.  Some methods of interest
include:

``Repository.getNextSerialNumber``
  Get the next number; calls ``checkRange`` before returning it

``Repository.checkRange``
  Check if the range is exhausted; if so call ``switchToNextRange``

``Repository.switchToNextRange``
  Switches to next range (see discussion in earlier section)

``Repository.checkRanges``
  Sanity checks the active and standby ranges; acquires new range
  allocation if necessary (by calling ``DBSubsystem.getNextRange``)
  and persists the changes to ``CS.cfg``.

``DBSubsystem.getNextRange``
  This method creates the LDAP range object and updates the
  ``nextRange`` attribute, returning the range bounds to the caller.


Fixing range conflicts
----------------------

If you have range conflicts, the following high-level steps can be
followed to fix them:

1. Stop all Dogtag servers.

#. Resolve any replication issues or conflict entries.

#. Examine active and standby ranges in ``CS.cfg`` on all replicas.

#. If there are any conflicts (including between active and standby
   ranges), choose new ranges such that there are no conflicts.
   Update ``CS.cfg`` of each replica with its new ranges.

#. Update the ``nextRange`` attribute for each repository object to
   a number *greater than* the highest number of any allocated
   range (*max + 1* is fine).  See appendix for the objects
   involved.

#. *(Optional)* Update and add new range entries.  This is not
   essential because nothing will break if the ranges entries don't
   actually correspond to what's in each replica's ``CS.cfg``.  But
   is is still desirable that the LDAP entries reflect the
   configuration of each server.

#. Start Dogtag servers.  If some servers do not have a standby
   range, it is a good idea to stagger their startup.  Otherwise
   there is a high risk of an immediate replication race causing
   range conflicts as servers acquire new range assignments.

Note that this procedure will *not* save your skin if, e.g.,
multiple certificates with the same serial number were issued.
Renewal problems may be unavoidable when collisions have occurred.
This is the main reason we are switching to `profile-based renewal`_
for FreeIPA system certificates.  Renewal requests refer to existing
certificate and requests by serial / request ID.  Thus if there have
been range conflicts they are susceptible to failure or issuance of
certificates with incorrect attributes.  Performing a "fresh
enrolment" when renewing system certificates avoids these problems
because the profile enrolment request does not refer to any existing
certificates or requests.

.. _profile-based renewal: https://pagure.io/freeipa/issue/7991
  

Discussion
----------

Dogtag is over 20 years old, and I suppose that sequential numbers
with range management made sense at the time.  Maybe a multi-server
deployment with a replicated database was not foreseen, and range
management was bolted on later when the requirement emerged.  Maybe
using random identifiers was seen as difficult to get write; UUIDs
were not widespread back then.  Or maybe using random numbers was
seen as not user-friendly (and that is true, but when you have more
than one replica the ranged identifiers aren't much better).

On the fact of some ranges using base 16 (hexademical) and others
using base 10: I cannot even imagine why this is so.  Extra user and
operator pain, for what gain?  I cannot tell.  The reasons are
probably, like so many things in old programs, lost in time.

The random serial number configuration and behaviour is… not state
of the art.  The program logic is difficult to follow and it is not
clear which configuration directives govern the (minimum) amount of
entropy in the chosen numbers.

If I were designing a system like Dogtag today, I would use random
UUIDs for everything, except possibly serial numbers.  There are
`122 bits of entropy`_ in a Version 4 UUID.  The current CA/Browser
Forum `Baseline Requirements`_ (v1.6.5) require serial numbers with
64 bits of high-quality randomness, but if that is ever increased
beyond 122 bits a UUID won't cut it anymore.  So I would just use
very large random numbers for all serial numbers.

.. _122 bits of entropy: https://en.wikipedia.org/wiki/UUID#Version_4_(random)
.. _Baseline Requirements: https://cabforum.org/wp-content/uploads/CA-Browser-Forum-BR-1.6.5.pdf

Can we move Dogtag from what we have now to something more robust?
Of course it is possible, but it would be a big effort.  So all that
is likely to happen is smaller, well understood and bounded efforts
with an obvious payoff, like avoiding range delegation (`Issue
3060`_).

The new FreeIPA `Health Check`_ system provides pluggable checks for
system health.  There is an open ticket to implement Dogtag range
conflict and sanity checking in the Health Check tool, so that
problems can be detected before they cause major failures.

.. _Health Check: https://www.freeipa.org/page/V4/Healthcheck



Appendix: range configuration directives and objects
----------------------------------------------------

In all LDAP DNs below, substitute ``o=ipaca`` with the relevant base
DN.

Certificate serial numbers
~~~~~~~~~~~~~~~~~~~~~~~~~~

Base: **hexademical**

``CS.cfg`` attributes::

  dbs.beginSerialNumber
  dbs.endSerialNumber
  dbs.nextBeginSerialNumber
  dbs.nextEndSerialNumber
  dbs.serialIncrement

LDAP repository object (``nextRange`` attribute)::

  dn: ou=certificateRepository,ou=ca,o=ipaca

LDAP ranges subtree parent::

  dn: ou=certificateRepository,ou=ranges,o=ipaca

CA requests
~~~~~~~~~~~

Base: **demical**

``CS.cfg`` attributes::

  dbs.beginRequestNumber
  dbs.endRequestNumber
  dbs.nextBeginRequestNumber
  dbs.nextEndRequestNumber
  dbs.requestIncrement

LDAP repository object (``nextRange`` attribute)::

  dn: ou=ca,ou=requests,o=ipaca

LDAP ranges subtree parent::

  dn: ou=requests,ou=ranges,o=ipaca

Replica numbers
~~~~~~~~~~~~~~~

Base: **demical**

``CS.cfg`` attributes::

  dbs.beginReplicaNumber
  dbs.endReplicaNumber
  dbs.nextBeginReplicaNumber
  dbs.nextEndReplicaNumber
  dbs.replicaIncrement

LDAP repository object (``nextRange`` attribute)::

  dn: ou=replica,o=ipaca

LDAP ranges subtree parent::

  dn: ou=replica,ou=ranges,o=ipaca


KRA keys
~~~~~~~~

Base: **hexademical**

``kra/CS.cfg`` attributes::

  dbs.beginSerialNumber
  dbs.endSerialNumber
  dbs.nextBeginSerialNumber
  dbs.nextEndSerialNumber
  dbs.serialIncrement

LDAP repository object (``nextRange`` attribute)::

  dn: ou=keyRepository,ou=kra,o=kra,o=ipaca

LDAP ranges subtree parent::

  dn: ou=keyRepository,ou=ranges,o=kra,o=ipaca

KRA requests
~~~~~~~~~~~~

Base: **demical**

``kra/CS.cfg`` attributes::

  dbs.beginRequestNumber
  dbs.endRequestNumber
  dbs.nextBeginRequestNumber
  dbs.nextEndRequestNumber
  dbs.requestIncrement

LDAP repository object (``nextRange`` attribute)::

  dn: ou=kra,ou=requests,o=kra,o=ipaca

LDAP ranges subtree parent::

  dn: ou=requests,ou=ranges,o=kra,o=ipaca

KRA replicas numbers
~~~~~~~~~~~~~~~~~~~~

Base: **demical**

``CS.cfg`` attributes::

  dbs.beginReplicaNumber
  dbs.endReplicaNumber
  dbs.nextBeginReplicaNumber
  dbs.nextEndReplicaNumber
  dbs.replicaIncrement

LDAP repository object (``nextRange`` attribute)::

  dn: ou=replica,o=kra,o=ipaca

LDAP ranges subtree parent::

  dn: ou=replica,ou=ranges,o=kra,o=ipaca

---
tags: dogtag, freeipa, troubleshooting
---

Diagnosing Dogtag cloning failures
==================================

Sometimes, creating a Dogtag clone or a FreeIPA CA replica fails.  I
worked with Dogtag and FreeIPA for nearly five years.  Over these
years I've analysed a lot of these clone/replica installation
failures and internalised a lot of knowledge about how cloning
works, and how it can break.  Often when I read a problem report and
inspect the logs I quickly get a "gut feeling" about the cause.  The
purpose of this post is to *externalise* my internal intuition so
that others can benefit.  Whether you are an engineer or not, this
post explains what you can do to get to the bottom of Dogtag cloning
failures faster.

How Dogtag clones are created
-----------------------------

Some notes about terminology: in FreeIPA we talk about *replicas*,
but in Dogtag we say *clones*.  These terms mean the same thing.
When you create a FreeIPA CA replica, FreeIPA creates a clone of the
Dogtag CA instance behind the scenes.  I will use the term *master*
to refer to the server from which the clone/replica is being
created.

The ``pkispawn(8)`` program, depending on its configuration, can be
used to create a new Dogtag subsystem or a clone.  ``pkispawn``, a
Python program, manages the whole clone creation process, with the
possible exception of setting up LDAP database and replication.  But
some stages of the configuration are handled by the Dogtag server
itself (thus implemented in Java).  Furthermore, the Dogtag server
on the *master* must service some requests to allow the new clone to
integrate into the topology.

The high level procedure of CA cloning is roughly:

#. (``ipa-replica-install``) Create temporary Dogtag admin user
   account and add to relevant groups

#. (``ipa-replica-install`` or ``pkispawn``) Establish LDAP
   replication of the Dogtag database

#. (``pkispawn``) Extract private keys and system certifiates into
   Dogtag's NSSDB

#. (``pkispawn``) Lay out the Dogtag instance on the filesystem

#. (``pkispawn``) Start the ``pki-tomcatd`` instance

#. (``pkispawn``) Send a *configuration request* to the new Dogtag
   instance

   #. (``pki-tomcatd`` on *clone*) Send *security domain* login
      request to master (using temporary admin user credentials)

   #. (``pki-tomcatd`` on *master*) Authenticate user, return
      cookie.

   #. (``pki-tomcatd`` on *clone*) Send number range requests to
      master

   #. (``pki-tomcatd`` on *master*) Service number range requests
      for clone

#. (``ipa-replica-install``) remove temporary admin user account

There are several places a problem could occur: in ``pkispawn``,
``pki-tomcatd`` on the clone, or ``pki-tomcatd`` on the master.
Therefore, depending on what failed, the best data about the failure
could be in ``pkispawn`` output/logs, the Dogtag ``debug`` log on
the replica, or the master, or even the system journal on either of
the hosts.  **Recommendation:** when analysing Dogtag cloning or
FreeIPA CA replica installation failures, inspect *all of these
logs*.  It is often not obvious where the error is occurring, or
what caused it.  Having all these log files helps a lot.


Case studies
------------

Failure to set up replication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

**Description**: ``ipa-replica-install`` or ``pkispawn`` fail with
errors related to replication (failure to establish).  I don't know
how common this is in production environments.  I've encountered it
in my development environments.  I *think* it is usually caused by
stale replication agreements or something of that nature.

**Workaround**: A "folk remedy": uninstall and clean up the
instance, then try again.  Most often the error does not recur.


Replication races
~~~~~~~~~~~~~~~~~

**Description:** ``pkispawn`` fails; *replica* ``debug`` log
indicates security domain login failure; *master* ``debug`` log
indicates user unknown; ``debug`` log indicates token/session
unkonwn

During cloning, the *clone* adds LDAP objects in its own database.
It then performs requests against the *master*, assuming that those
objects (or effects of other LDAP operations) have been replicated
to the master.  Due to replication lag, the data have not been
replicated and as a consequence, a request fails.

In the past couple of years several replication races were
discovered and fixed (or mitigated) in Dogtag or FreeIPA:

``updateNumberRange`` failure due to missing session object
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

**Ticket**: https://pagure.io/dogtagpki/issue/2557

**Description**: After security domain login (locally on the
*replica*) the session object gets replicated to the *master*.  The
cookie/token conveyed in the ``updateNumberRange`` range referred to
a session that the *master* did not yet know about.

**Resolution**: the *replica* sleeps (duration configuration;
default 5s) after security domain login, giving time for
replication.  This is not guaranteed the avoid the problem: the
complete solution (yet to be implemented) will be to `use a
signed/MACed token <https://pagure.io/dogtagpki/issue/2831>`_.


Security domain login failure due to missing user or group membership
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

**Ticket**: https://pagure.io/freeipa/issue/7593

**Description**: This bug was actually in FreeIPA, but manifested in
``pki-tomcatd`` on *master* as a failure to log into the security
domain.  This could occur for one of two reasons: either the user
was unknown, or the user was not a member of a required group.
FreeIPA performs the relevant LDAP operations on the *replica*, but
they have not replicated to *master* yet.  The
``pkispawn``/``ipa-replica-install`` error message looks something
like::

  com.netscape.certsrv.base.PKIException: Failed to obtain
  installation token from security domain:
  com.netscape.certsrv.base.UnauthorizedException: User
  admin-replica1.ipa.example is not a member of Enterprise CA
  Administrators group.

**Workaround**: no supported workaround.  (You could hack in a
``sleep`` though).

**Resolution**: The user creation routine was already waiting for
replication but the wait routine had a timeout bug causing false
positives, *and* the group memberships were not being waited on.
The timeout bug was fixed.  The wait routine was enhanced to support
waiting for particular attribute values; this feature was used to
ensure group memberships have been replicated before continuing.


Other ``updateNumberRange`` failures
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

**Ticket**: https://pagure.io/dogtagpki/issue/3055

**Description**: When creating a clone from a master that was itself
a clone, an ``updateNumberRange`` request fails at *master* with
status 500.  A ``NullPointerException`` backtrace appears in the
journal for the ``pki-tomcatd@pki-tomcat`` unit (on *master*).  The
problem arises because the initial number range assignment for the
second clone is equal to the range size of the first clone (range
transfer size is a fixed number).  This scenario was not handled
correctly, leading to the exception.

**Workaround**: Ensure that each clone
services one of each kind of number (e.g. one full certificate
request and issuance operation).  This ensures that the clone's
range is smaller than the range transfer size, so that a subsequent
``updateNumberRange`` request will be satisfied from the master's
"standby" range.

**Resolution**: detect range depletion due to ``updateNumberRange``
requests and eagerly switch to the standby range.  A better fix (yet
to be implemented) will be to `allocate each clone a full-sized
range <https://pagure.io/dogtagpki/issue/3060>`_ from the
unallocated numbers.


Discussion
----------

Dogtag subsystem cloning is a complex procedure.  Even more so in
the FreeIPA context.  There are lots of places failure can occur.

The case studies above are a few examples of difficult-to-debug
failures where the cause was non-obvious.  Often the error occurs on
a different host (the *master*) from where the error was observed.
And the important data about the true cause may reside in
``ipareplica-install.log``, ``pkispawn`` log output, the Dogtag CA
``debug`` log (on *replica* or *master*) or the system journal
(again on *replica* or *master*).  Sometimes the 389DS logs can be
helpful too.

Normally the fastest way to understand a problem is to gather all
these sources of data and look at them all around the time the error
occurred.  When you see one failure, don't assume that that is *the*
failure.  Cross-reference the log files.  If you can't see anything about an error, you probably
need to look in a different file…

…or a different part of the file!  It is important to note that
**Dogtag time stamps are in local time**, whereas most other logs
are UTC.  Different machines in the topology can be in different
timezones, so you could be dealing with up to three timezones across
the log files.  Check carefully what timezone the timestamps are in
when you are "lining up" the logfiles.  Many times I have seen (and
often erred myself) an incorrect conclusion that "there is no error
in the debug log" because of this trap.

In my experience, the most common causes of Dogtag cloning failure
have involved Security Domain authentication issues and number range
management.  Over time I and others have fixed several bugs in these
areas, but I am not confident that all potential problems have been
fixed.  The good news is that checking *all* the relevant logs
usually leads to a good theory about the root cause.

What if you are not an engineer or not able to make sense of the
Dogtag codebase?  (This is fine by the way—Dogtag is a huge, gnarly
beast!) The best thing you can do to help us analyse and resolve the
issue is to collect *all* the logs (from the master and replica) and
prune them to the relevant timeframe (minding the timezones) before
passing them to an engineer for analysis.

In this post I only looked at Dogtag cloning failures.  I have lots
of other Dogtag "gut knowledge" that I plan to get out in upcoming
posts.

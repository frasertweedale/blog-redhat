LDAP persistent searches with ldapjdk
=====================================

As part of the `LDAP-based profiles`_ feature I've been working on
for the Dogtag_, it was necessary to implement a feature where the
database is monitored for changes to the LDAP profiles.  For
example, when a profile is updated on a clone, that change is
replicated to other clones, and those other clones have to detect
that change and each instance must update its view of the profiles
accordingly.  This post details how the LDAP *persistent search*
feature was used to implement this behaviour.

.. _LDAP-based profiles: http://pki.fedoraproject.org/wiki/LDAP_Profile_Storage
.. _Dogtag: http://pki.fedoraproject.org/wiki/PKI_Main_Page

A naïve approach to solving this problem would have been to
unconditionally refresh all profiles at a certain interval.
Slightly better would be to *check* all profiles at a certain
interval and update those that have changed.  Both of these methods
involve some non-trivial delay between changes being replicated to
the local database, and the profile subsystem reflecting those
changes.

A different approach was to use the LDAP persistent search
capability.  With this feature, once the search is running, the
client receives immediate notification of changes.  This advantage
commended it over the polling approach as a more appropriate basis
for a solution.


ldapjdk persistent search API
-----------------------------

A big part of the motivation for this post was the paucity of the
ldapjdk documentation with respect to persistent searches.  The
necessary information is all there - but it is scattered across
several classes, all of which play some important part in a working
implementation, but none of which tells the full story.

Hopefully some people will benefit from this information being
brought together in one place and explained step by step.  Let's
look at the classes involved one by one as we build up the solution.


``LDAPPersistSearchControl``
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

This is the server control that activates the persistent search
behaviour.  It also provides static flags for specifying what
kinds of updates to listen for.  Its constructor takes a union of
these flags and three ``boolean`` values:

``changesOnly``
  Whether to return existing entries that match the search criteria.
  For our use case, we are only interested in changes.
``returnControls``
  Whether to return entry change controls with each search result.
  These controls are required if you need to know what kind of
  change occured (add, modify, delete or modified DN).
``isCritical``
  Whether this control is critical to the search operation.

The ``LDAPPersistSearchControl`` object used for our persistent
search is constructed in the following way:

.. code:: java

    int op = LDAPPersistSearchControl.ADD
        | LDAPPersistSearchControl.MODIFY
        | LDAPPersistSearchControl.DELETE
        | LDAPPersistSearchControl.MODDN;
    LDAPPersistSearchControl persistCtrl =
        new LDAPPersistSearchControl(op, true, true, true);


``LDAPSearchConstraints``
^^^^^^^^^^^^^^^^^^^^^^^^^

The ``LDAPSearchConstraints`` object sets various controls and
parameters for an LDAP search, persistent or otherwise.  In our
case, we need to attach the ``LDAPPersistSearchControl`` to the
constraints, as well as disable the timeout of the search, and set
the results batch size to ``1`` so that no buffering of results will
occur at the server:

.. code:: java

    LDAPSearchConstraints cons = conn.getSearchConstraints();
    cons.setServerControls(persistCtrl);
    cons.setBatchSize(1);
    cons.setServerTimeLimit(0 /* seconds */);


``LDAPSearchResults``
^^^^^^^^^^^^^^^^^^^^^

Executing the ``search`` method of an ``LDAPConnection`` (here named
``conn``), yields an ``LDAPSearchResults`` object.  This is the same
whether or the search was a persistent search according to the
``LDAPSearchConstraints``.  The different between persistent and
non-persistent searches is in how results are retrieved from the
results object: if the search is persistent, the ``hasMoreElement``
method will block until the next result is received from the server
(or the search times out, the connection dies, et cetera).

Let's see what it looks like to actually execute the persistent
search and process its results:

.. code:: java

    LDAPConnection conn = ... /* an open LDAPConnection */

    LDAPSearchResults results = conn.search(
        "ou=certificateProfiles,ou=ca," + basedn, /* search DN */
        LDAPConnection.SCOPE_ONE, /* search at one level below DN */
        "(objectclass=*)",        /* search filter */
        null,   /* list of attributes we care about */
        false,  /* whether to only include specified attributes */
        cons    /* LDAPSearchConstraints defined above */
    );
    while (results.hasMoreElements()) /* blocks */ {
        LDAPEntry entry = results.next();
        /* ... process result ... */
    }

We see that apart from the use of the ``LDAPSearchConstraints`` to
specify a persistent search and the blocking behaviour of
``LDAPSearchResults.hasMoreElements``, performing a persistent
search is the same as performing a regular search.

Let us next examine what happens inside that ``while`` loop.


``LDAPEntryChangeControl``
^^^^^^^^^^^^^^^^^^^^^^^^^^

Do you recall the ``returnControls`` parameter for
``LDAPPersistSearchControl``?  If ``true``, it ensures that each
entry returned by the persistent search is accompanied by a control
that indicates the type of change that affected the entry.  We need
to know this information so that we can update the *profile
subsystem* in the appropriate way (*was this profile added, updated,
or deleted?*)

Let's look at how we do this.  We are inside the ``while`` loop from
above, starting exactly where we left off:

.. code:: java

    LDAPEntry entry = results.next();
    LDAPEntryChangeControl changeControl = null;
    for (LDAPControl control : results.getResponseControls()) {
        if (control instanceof LDAPEntryChangeControl) {
            changeControl = (LDAPEntryChangeControl) control;
            break;
        }
    }
    if (changeControl != null) {
        int changeType = changeControl.getChangeType();
        switch (changeType) {
        case LDAPPersistSearchControl.ADD:
            readProfile(entry);
            break;
        case LDAPPersistSearchControl.DELETE:
            forgetProfile(entry);
            break;
        case LDAPPersistSearchControl.MODIFY:
            forgetProfile(entry);
            readProfile(entry);
            break;
        case LDAPPersistSearchControl.MODDN:
            /* shouldn't happen; log a warning and continue */
            CMS.debug("Profile change monitor: MODDN shouldn't happen; ignoring.");
            break;
        default:
            /* shouldn't happen; log a warning and continue */
            CMS.debug("Profile change monitor: unknown change type: " + changeType);
            break;
        }
    } else {
        /* shouldn't happen; log a warning and continue */
        CMS.debug("Profile change monitor: no LDAPEntryChangeControl in result.");
    }

The first thing that has to be done is to retrieve from the
``LDAPSearchResults`` object the ``LDAPEntryChangeControl`` for the
most recent search result.  To do this we call
``results.getResponseControls()``, which returns an
``LDAPControl[]``.  Each search result can arrive with multiple
change controls, but we are specifically interested in the
``LDAPEntryChangeControl`` so we iterate over the ``LDAPControl[]``
until we find what we want, then ``break``.

Next we ensure that we did in fact find the
``LDAPEntryChangeControl``.  This *should* always hold in our
implementation but the code should handle the failure case anyway -
 we just log a warning and move on.

Finally, we call ``changeControl.getChangeType()`` and dispatch to
the appropriate behaviour according to its value.


Interaction with the profile subsystem
--------------------------------------

Up to this point, we have seen how to use the ldapjdk API to execute
a persistent LDAP search and process its results.  Of course, this
is just part of the story - the search somehow needs to be run in a
way that doesn't impede the regular operation of the Dogtag PKI, and
needs to safely interact with the *profile subsystem*.  Because the
persistent search involves blocking calls, the procedure needs to
run in its own *thread*.

Because this persistent search only concerns the
``ProfileSubsystem`` class, it was possible to completely
encapsulate it within this class such that no changes to its API
(including constructors) were necessary.  An *inner class*
``Monitor``, which extends ``Thread``, actually runs the search.  In
this way, the code we saw above is neatly segregated from the rest
of the ``ProfileSubsystem`` class, and there are no visibility
issues when calling the ``readProfile`` and ``forgetProfile``
methods of the other class.

The following simplified code conveys the essence of the complete
implementation:

.. code:: java

    public class ProfileSubsystem implements IProfileSubsystem {
        public void init(...) {
            // Read profiles from LDAP into the subsystem.
            // Calls readProfile for each existing LDAPEntry.

            monitor = new Monitor(this, dn, dbFactory);
            monitor.start();
        }

        public synchronized IProfile createProfile(...) {
            // Create the profile
        }

        public void readProfile(LDAPEntry entry) {
            // Read some LDAP attributes into local vars
            createProfile(...);
        }

        private void forgetProfile(LDAPEntry entry) {
            profileId = /* read from entry */
            forgetProfile(profileId);
        }

        private void forgetProfile(String profileId) {
            // Forget about this profile.
        }

        private class Monitor extends Thread {
            public Monitor(...) {
                // constructor
            }

            public void run() {
                // Execute the persistent search as above.
                //
                // Calls readProfile and forgetProfile depending
                // on changes that occur.
            }
        }
    }

So, what's going on here?  First of all, it must be emphasised that
this example is simplified.  For example, I have omitted details of
how the monitor thread is stopped when the subsystem is shut down or
reinitialised.

The monitor thread is started by the ``init`` method, once the
existing profiles have been read into the profile subsystem.
Executing the persistent search and handling results is the one job
this the monitor has to do, so it can block without affecting any
other part of the system.  When it receives results, it calls the
``readProfile`` and ``forgetProfiles`` methods of the outer class -
 the ``ProfileSubsystem`` - to keep it up to date with the contents
of the database.

Other parts of the system access the ``ProfileSubsystem`` as well,
so consideration had to be given to synchronisation and making sure
that changes to the contents of the ``ProfileSubsystem`` are done
safely.  In the end, the only method that was made ``synchronized``
was ``createProfile``, which is also called by the REST interface.
The behaviour of the handful of other methods that could be called
simultaneously should be fine by virtue of the fact that the
internal data structures used are themselves synchronised and
idempotent.  Hopefully I have not overlooked something important!


Conclusion
----------

LDAP persistent searches can be used to receive immediate
notification of changes that occur in an LDAP database.  They
support all the parameters of regular LDAP searches.  ldapjdk's API
provides persistent search capabilities including the ability to
discern what kind of change occurred for each result.

The ldapjdk ``LDAPSearchResults.hasMoreElements()`` method blocks
each time it is called until a result has been received from the
server.  Because of this, it will usually be necessary to execute
persistent searches asynchronously.  Java threads can be employed to
do this, but the usual "gotchas" of threading apply - threads must
be stopped safely and the safety of methods that could be called
from multiple places at the same time must be assessed.  The
``synchronized`` keyword can be used to ensure serialisation of
calls to methods that would otherwise be unsafe under these
conditions.

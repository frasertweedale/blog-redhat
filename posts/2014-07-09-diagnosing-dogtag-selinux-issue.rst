---
tags: dogtag, sysadmin, troubleshooting
---

Diagnosing a Dogtag SELinux Issue
=================================

In this post, I explain an issue I had with Dogtag failing to start
due to some recently added behaviour that was prohibited by Fedora's
SELinux security policy, and detail the steps that were taken to
resolve it.


The Problem
-----------

A recent commit to Dogtag added the ability to archive each
subsystem's configuration file on startup.   This feature is turned
on by default.  On each startup, each subsystem's ``CS.cfg`` is
copied to
``/etc/pki/<instance>/<subsystem>/archives/CS.cfg.bak.<timestamp>``.
A symbolic link pointing to the archived file named ``CS.cfg.bak``
is then created in the parent directory of ``archives/``, alongside
``CS.cfg``.

Having built and installed a development version of Dogtag that
contained this new feature, I attempted to start Dogtag, but
the service failed to start.

::

  % sudo systemctl start pki-tomcatd@pki-tomcat.service
  Job for pki-tomcatd@pki-tomcat.service failed. See 'systemctl status pki-tomcatd@pki-tomcat.service' and 'journalctl -xn' for details.

The error message gave some advice on what to do next, so I followed
its advice.

::

  % systemctl status pki-tomcatd@pki-tomcat.service
  pki-tomcatd@pki-tomcat.service - PKI Tomcat Server pki-tomcat
     Loaded: loaded (/usr/lib/systemd/system/pki-tomcatd@.service; enabled)
     Active: failed (Result: exit-code) since Tue 2014-07-08 21:22:42 EDT; 1min 10s ago
    Process: 26699 ExecStop=/usr/libexec/tomcat/server stop (code=exited, status=1/FAILURE)
    Process: 26653 ExecStart=/usr/libexec/tomcat/server start (code=exited, status=143)
    Process: 32704 ExecStartPre=/usr/bin/pkidaemon start tomcat %i (code=exited, status=1/FAILURE)
   Main PID: 26653 (code=exited, status=143)

  Jul 08 21:22:42 ipa-1.ipa.local systemd[1]: Starting PKI Tomcat Server pki-tomcat...
  Jul 08 21:22:42 ipa-1.ipa.local pkidaemon[32704]: ln: failed to create symbolic link ‘/var/lib/pki/pki-tomcat/conf/ca/CS.cfg.bak’: Permission denied
  Jul 08 21:22:42 ipa-1.ipa.local pkidaemon[32704]: SUCCESS:  Successfully archived '/var/lib/pki/pki-tomcat/conf/ca/archives/CS.cfg.bak.20140708212242'
  Jul 08 21:22:42 ipa-1.ipa.local pkidaemon[32704]: WARNING:  Failed to backup '/var/lib/pki/pki-tomcat/conf/ca/CS.cfg' to '/var/lib/pki/pki-tomcat/conf/ca/CS.cfg.bak'!
  Jul 08 21:22:42 ipa-1.ipa.local pkidaemon[32704]: /usr/share/pki/scripts/operations: line 1579: 0: command not found
  Jul 08 21:22:42 ipa-1.ipa.local systemd[1]: pki-tomcatd@pki-tomcat.service: control process exited, code=exited status=1
  Jul 08 21:22:42 ipa-1.ipa.local systemd[1]: Failed to start PKI Tomcat Server pki-tomcat.
  Jul 08 21:22:42 ipa-1.ipa.local systemd[1]: Unit pki-tomcatd@pki-tomcat.service entered failed state.

``journalctl -xn`` gave essentially the same information as above.
We can see that creation of the symbolic link failed, which led to a
subsequent warning and failure to start the service.  Interestingly,
we can also see that creation of
``archives/CS.cfg.bak.20140708212242`` (the target of the symbolic
link) was reported to have succeeded.

The user that runs the Dogtag server is ``pkiuser``, and everything
seemed fine with the permissions in ``/etc/pki/pki-tomcat/ca/``.
The archived configuration file that was reported to have been
created successfully was indeed there.

Next I looked at the Dogtag startup routines, which live in
``/usr/share/pki/script/operations``.  I located the offending ``ln
-s`` and replaced it with a ``cp``, that is, instead of creating a
symbolic link, the startup script would now simply create
``CS.cfg.bak`` as a copy of the archived configuration file.  Having
made this change, I tried to start Dogtag again, and it succeeded.
Something was prohibiting the creation of the symbolic link.


The Culprit
-----------

That something was *SELinux*.

SELinux_ (Security-Enhanced Linux) is `mandatory access control`_
system for Linux that can be used to express and enforce detailed
security policies.  It is enabled by default in recent version of
Fedora, which ships with a reasonable default set of security
policies.

.. _SELinux: http://selinuxproject.org/page/Main_Page
.. _mandatory access control: http://en.wikipedia.org/wiki/Mandatory_access_control


The Workaround
--------------

To continue the diagnosis of this problem, I restored the original
behaviour of the startup script, i.e. creating a symbolic link, and
confirmed that Dogtag was once again failing to start.

The next step was to look for a way to get SELinux to permit the
operation.  I soon discovered ``setenforce(8)``, which is used to
put SELinux into *enforcing mode* (``setenforce 1``; the default
behaviour) or *permissive mode* (``setenforce 0``).  As expected,
running ``sudo setenforce 0`` allowed Dogtag startup to succeed
again, but obviously this was not a solution - merely a temporary
workaround, acceptable in a development environment, but
unacceptable for our customers and users.


The Plumbing
------------

Having little prior experience with SELinux, and since it had
reached the end of the day, I emailed the other developers for
advice on how to proceed.  Credit goes to Ade Lee for most of the
information that follows.

SELinux logs to ``/var/log/audit/audit.log`` (on Fedora, at least).
This log contains details about operations that SELinux denied (or
would have denied, if it was enforcing).  This log can be read by
the ``audit2allow(1)`` tool, to construct SELinux rules that would
allow the operations that were denied.  First, the log was
truncated, so it will include only the relevant failures::

  % sudo sh -c ':>/var/log/audit/audit.log'

Next, with SELinux *still in permissive mode* so that all operations
that would otherwise be denied throughout the startup process
will be permitted but logged, I started the server via ``systemctl``
as before.  Startup succeeded, and audit log now contained
information about all the *would-have-failed* operations.  Here is a
short excerpt from the audit log (three lines, wrapped)::

  type=AVC msg=audit(1404872081.435:1006): avc:  denied  { create }
    for  pid=1298 comm="ln" name="CS.cfg.bak"
    scontext=system_u:system_r:pki_tomcat_t:s0
    tcontext=system_u:object_r:pki_tomcat_etc_rw_t:s0 tclass=lnk_file
  type=SYSCALL msg=audit(1404872081.435:1006): arch=c000003e
    syscall=88 success=yes exit=0 a0=7fff6b27aac0 a1=7fff6b27ab03 a2=0
    a3=7fff6b278790 items=0 ppid=1113 pid=1298 auid=4294967295 uid=994
    gid=994 euid=994 suid=994 fsuid=994 egid=994 sgid=994 fsgid=994
    tty=(none) ses=4294967295 comm="ln" exe="/usr/bin/ln"
    subj=system_u:system_r:pki_tomcat_t:s0 key=(null)
  type=AVC msg=audit(1404872081.436:1007): avc:  denied  { read }
    for  pid=1113 comm="pkidaemon" name="CS.cfg.bak" dev="vda3"
    ino=134697 scontext=system_u:system_r:pki_tomcat_t:s0
    tcontext=system_u:object_r:pki_tomcat_etc_rw_t:s0 tclass=lnk_file

There were about 30 lines in the audit log.  As expected, there were
entries related to the failure to create a symbolic link - those are
the lines above.  There were also entries that didn't seem related
to the symlink failure, yet were obviously caused by the Dogtag
startup.

To one unfamiliar with SELinux, the format of the audit log and the
meaning of the entries therein is somewhat opaque.  Running ``sudo
audit2why -a`` distils the audit log into more human-friendly
information, giving information about six denials including the
symlink denial::

  type=AVC msg=audit(1404872081.435:1006): avc:  denied  { create } for  pid=1298 comm="ln" name="CS.cfg.bak" scontext=system_u:system_r:pki_tomcat_t:s0 tcontext=system_u:object_r:pki_tomcat_etc_rw_t:s0 tclass=lnk_file
          Was caused by:
                  Missing type enforcement (TE) allow rule.

                  You can use audit2allow to generate a loadable module to allow this access.

Each message gives the user, operation and labels of resources
involved in the denied operation, and the cause of the denial.  It
also suggests using ``audit2allow(1)`` to generate the rules that
would allow the failed operations.  Running ``sudo audit2allow -a``
gave the following output::

  #============= pki_tomcat_t ==============

  #!!!! This avc is a constraint violation.  You would need to modify the attributes of either the source or target types to allow this access.
  #Constraint rule:
          constrain file { create relabelfrom relabelto } ((u1 eq u2 -Fail-)  or (t1=pki_tomcat_t  eq TYPE_ENTRY -Fail-) { POLICY_SOURCE: can_change_object_identity } ); Constraint DENIED

  #       Possible cause is the source user (system_u) and target user (unconfined_u) are different.
  allow pki_tomcat_t pki_tomcat_etc_rw_t:file create;
  allow pki_tomcat_t pki_tomcat_etc_rw_t:file { relabelfrom relabelto };
  allow pki_tomcat_t pki_tomcat_etc_rw_t:lnk_file { read create };
  allow pki_tomcat_t self:process setfscreate;

I have no idea about the meanings of the warning and the
``constrain`` rule, but the other rules make more sense.  In
particular, the second-last rule is undoubtedly the one that will
allow the creation of symbolic links.  Without knowing the specifics
of this rule format, I would interpret this line as,

  Allow processes with the ``pki_tomcat_t`` attribute to create and
  read symbolic links in in areas (of the filesystem) with the
  ``pki_tomcat_etc_rw_t`` attribute.

Admittedly, I have inferred *processes* and *filesystem* above, in
no small part due to the names ``pki_tomcat_t`` and
``pki_tomcat_etc_rw_t``, which were probably chosen by the Dogtag
developers.  Nevertheless, the rule format seems to do a
satisfactory job of communicating the meaning of a rule, especially
when descriptive labels are used.


The Fix
-------

The SELinux policies that permit Dogtag to manage its affairs
(configuration, logging, etc.) on a Fedora system are not shipped in
the ``pki-*`` packages, but rather in the
``selinux-policy-targeted`` package, which provides policies for
Dogtag and many other network servers and programs.

For an issue in this package to be corrected, one has to file a bug
against the ``selinux-policy-targeted`` component of the *Fedora*
product on the Red Hat Bugzilla.  A *reference policy* should be
attached to the bug report; ``audit2allow`` will generate one when
invoked with the ``-R`` or ``-reference`` argument.

::

  % sudo audit2allow -R -i /var/log/audit/audit.log > pki-lnk_file.te
  could not open interface info [/var/lib/sepolgen/interface_info]

This failed, but a web search soon revealed that the appropriate
interface is generated by the ``sepolgen-ifgen`` command, which is
provided by the ``policycoreutils-devel`` package.

::

  % sudo yum install -y policycoreutils-devel
  % sudo sepolgen-ifgen
  % sudo audit2allow -R -i /var/log/audit/audit.log > pki-lnk_file.te
  % cat pki-lnk_file.te

  require {
          type pki_tomcat_etc_rw_t;
          type pki_tomcat_t;
          class process setfscreate;
          class lnk_file { read create };
          class file { relabelfrom relabelto create };
  }

  #============= pki_tomcat_t ==============

  #!!!! This avc is a constraint violation.  You would need to modify the attributes of either the source or target types to allow this access.
  #Constraint rule:
          constrain file { create relabelfrom relabelto } ((u1 eq u2 -Fail-)  or (t1=pki_tomcat_t  eq TYPE_ENTRY -Fail-) { POLICY_SOURCE: can_change_object_identity } ); Constraint DENIED

  #       Possible cause is the source user (system_u) and target user (unconfined_u) are different.
  allow pki_tomcat_t pki_tomcat_etc_rw_t:file create;
  allow pki_tomcat_t pki_tomcat_etc_rw_t:file { relabelfrom relabelto };
  allow pki_tomcat_t pki_tomcat_etc_rw_t:lnk_file { read create };
  allow pki_tomcat_t self:process setfscreate;

With ``pki-link_file.te`` in hand, I `filed a bug`_.  Hopefully
the package will be updated soon.

.. _filed a bug: https://bugzilla.redhat.com/show_bug.cgi?id=1117673


Conclusion
----------

When I first ran into this issue, I had very little experience with
SELinux.  I now know a fair bit more than I used to - how to quickly
determine whether SELinux is responsible for a given failure, and
what the operations were that failed - but there is much more to
learn about the workings of SELinux and the definition and
organisation of policies.

As to the occurrence of the problem itself, whilst from a security
standpoint it makes sense to separate the granting of privileges to
software from the provision of that software, as a developer, it
frustrated me that I had to submit a request to another team
responsible for a different aspect of Fedora just for Dogtag to be
able to create a symbolic link in its own configuration directory!

This arrangement of having the policies for myriad common servers
and programs provided centrally by one or two packages is new to me.
There are obvious merits to this approach - and obvious drawbacks.
Perhaps there is another approach that represents the best of both
worlds - security for the user, and convenience or lack of
roadblocks for the developer.  Perhaps I am talking about
containers_, à la Docker_.

.. _containers: http://en.wikipedia.org/wiki/Operating_system-level_virtualization
.. _Docker: https://www.docker.com/

In the mean time, until the ``selinux-policy-targeted`` package is
updated to add the symbolic link rules Dogtag needs, with SELinux
still in permissive mode on my development VM, I can get on with the
job of implementing `LDAP profile storage`_ in Dogtag.

.. _LDAP profile storage: http://pki.fedoraproject.org/wiki/LDAP_Profile_Storage

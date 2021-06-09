---
tags: systemd, cgroups, containers
---

# systemd, cgroups and subuid ranges

In my [previous post][] I experimented with `runc` as a way of
understanding the behaviour of OCI runtimes.  I ended up focusing on
cgroup creation and the interaction between `runc` and *systemd*.
The experiment revealed a critical deficiency: when using user
namespaces the container's cgroup is not owned by the user executing
the container process.  As a result, *systemd*-based workloads
cannot run.

`runc` creates cgroups via systemd's *transient unit API*.  Could
a container runtime use this API to control the cgroup ownership?
Let's find out.

[previous post]: 2021-05-27-oci-runtime-spec-runc.html

## How `runc` talks to *systemd*

The *Open Container Initiative (OCI)* [runtime spec][] defines a
low-level container runtime interface.  OCI runtimes must create the
Linux namespaces specified by an OCI config, including the cgroup
namespace.

`runc` uses the systemd D-Bus API to ask systemd to create a cgroup
scope for the container.  Then it creates a cgroup namespace with
the new cgroup scope as the root.  We can see that `runc` invokes
the `StartTransientUnit` API method with a name for the new unit,
and a list of properties
([source code](https://github.com/opencontainers/runc/blob/v1.0.0-rc95/vendor/github.com/coreos/go-systemd/v22/dbus/methods.go#L198-L200)):

```go
// .../go-systemd/v22/dbus/methods.go
func (c *Conn) StartTransientUnitContext(
  ctx context.Context, name string, mode string,
  properties []Property, ch chan<- string) (int, error) {
  return c.startJob(
    ctx, ch,
    "org.freedesktop.systemd1.Manager.StartTransientUnit",
    name, mode, properties, make([]PropertyCollection, 0))
}
```

Most of the unit configuration is passed as properties.

## The `User=` property

[`systemd.exec(5)`][systemd.exec(5)] describes the properties that
configure a systemd unit (including transient units).  Among the
properties are `User=` and `Group=`:

> Set the UNIX user or group that the processes are executed as,
> respectively. Takes a single user or group name, or a numeric ID
> as argument.

This sounds promising.  Further searching turned up a systemd
documentation page entitled [Control Group APIs and
Delegation][CGROUP_DELEGATION].  That document states:

> By turning on the `Delegate=` property for a scope or service you
> get a few guarantees: … If your service makes use of the `User=`
> functionality, then the sub-tree will be `chown()`ed to the
> indicated user so that it can correctly create cgroups below it.

`runc` already supplies `Delegate=true`.  The `User=` property seems
to be exactly what we need.

[runtime spec]: https://github.com/opencontainers/runtime-spec
[systemd.exec(5)]: https://www.freedesktop.org/software/systemd/man/systemd.exec.html#User=
[CGROUP_DELEGATION]: https://systemd.io/CGROUP_DELEGATION/


## Determining the UID

The OCI configuration specifies the [`user`][oci-user] that will
execute the container process (in the **container's user
namespace**).  It also specifies [`uidMappings`][oci-uidMappings]
between the host and container user namespaces.  For example:

```shell
% jq -c '.process.user, .linux.uidMappings' < config.json
{"uid":0,"gid":0}
[{"containerID":0,"hostID":100000,"size":65536}]
```

`runc` has all the data it needs to compute the appropriate value
for the `User=` property.  The algorithm, expressed as Python is:

```python
uid = config["process"]["user"]["uid"]

for map in config["linux"]["uidMappings"]:
    uid_min = map["containerID"]
    uid_max = map_min + map["size"] - 1

    if uid_min <= uid <= uid_max:
        offset = uid - uid_min
        return map["hostID"] + offset

else:
    raise RuntimeError("user.uid is not mapped")
```

[oci-user]: https://github.com/opencontainers/runtime-spec/blob/master/config.md#posix-platform-user
[oci-uidMappings]: 


## Testing with `systemd-run`

`systemd-run(1)` uses the transient unit API to run programs via
transient scope or service units.  You can use the `--property`/`-p`
option to pass additional properties.  I used `systemd-run` to
observe how systemd handles the `Delegate=true` and `User=`
properties.

### Create and inspect transient unit

First I will do a basic test, talking to my user account's service
manager:

```shell
% id -u
1000

% systemd-run --user sleep 300
Running as unit: run-r8e3c22d2bb64491a85882d8303202dca.service

% systemctl --user status run-r8e3c22d2bb64491a85882d8303202dca.service
● run-r8e3c22d2bb64491a85882d8303202dca.service - /bin/sleep 300
     Loaded: loaded (/run/user/1000/systemd/transient/run-r8e3c22d2bb64491a85882d8303202dca.service; transient)
  Transient: yes
     Active: active (running) since Wed 2021-06-09 11:31:14 AEST; 9s ago
   Main PID: 11412 (sleep)
      Tasks: 1 (limit: 2325)
     Memory: 184.0K
        CPU: 3ms
     CGroup: /user.slice/user-1000.slice/user@1000.service/app.slice/run-r8e3c22d2bb64491a85882d8303202dca.service
             └─11412 /bin/sleep 300

Jun 09 11:31:14 f33-1.ipa.local systemd[863]: Started /bin/sleep 300.

% ls -nld /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/run-r8e3c22d2bb64491a85882d8303202dca.service
drwxr-xr-x. 2 1000 1000 0 Jun  9 11:31 /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/run-r8e3c22d2bb64491a85882d8303202dca.service
```

We can see that:

- systemd-run creates the transient unit
- the unit was started successfully, and is running
- the unit has is own `CGroup`
- the cgroup is owned by user `1000`

As I try different ways of invoking `systemd-run`, I will repeat
this pattern of unit creation, inspection and cgroup ownership
checks.

### Specify `User=` (user service manager)

Next I explicity specify `User=1000`:

```shell
% systemd-run --user -p User=1000 sleep 300
Running as unit: run-r651ff7d0d1214037b70def6d5694dcd6.service

% systemctl --no-pager --full --user status run-r651ff7d0d1214037b70def6d5694dcd6.service
× run-r651ff7d0d1214037b70def6d5694dcd6.service - /bin/sleep 300
     Loaded: loaded (/run/user/1000/systemd/transient/run-r651ff7d0d1214037b70def6d5694dcd6.service; transient)
  Transient: yes
     Active: failed (Result: exit-code) since Wed 2021-06-09 11:38:50 AEST; 1min 17s ago
    Process: 11432 ExecStart=/bin/sleep 300 (code=exited, status=216/GROUP)
   Main PID: 11432 (code=exited, status=216/GROUP)
        CPU: 4ms

Jun 09 11:38:50 f33-1.ipa.local systemd[863]: Started /bin/sleep 300.
Jun 09 11:38:50 f33-1.ipa.local systemd[11432]: run-r651ff7d0d1214037b70def6d5694dcd6.service: Failed to determine supplementary groups: Operation not permitted
Jun 09 11:38:50 f33-1.ipa.local systemd[11432]: run-r651ff7d0d1214037b70def6d5694dcd6.service: Failed at step GROUP spawning /bin/sleep: Operation not permitted
Jun 09 11:38:50 f33-1.ipa.local systemd[863]: run-r651ff7d0d1214037b70def6d5694dcd6.service: Main process exited, code=exited, status=216/GROUP
Jun 09 11:38:50 f33-1.ipa.local systemd[863]: run-r651ff7d0d1214037b70def6d5694dcd6.service: Failed with result 'exit-code'.
```

This unit failed to execute, because the user service manager does
not have permission to determine supplementary groups.  Without
going into too much detail, this is because the user systemd
instance lacks the `CAP_SETGID` capability required by the
`setgroups(2)` system call used by `initgroups(3)`.

There doesn't seem to be a way around this.  For the rest of my
testing I'll talk to the system service manager.  That's okay,
because `runc` on OpenShift also talks to the system service
manager.

### Specify `User=` (system service manager)

```shell
% sudo systemd-run -p User=1000 sleep 300
Running as unit: run-r94725453119e4003af336d7294984085.service

% systemctl status run-r94725453119e4003af336d7294984085.service
● run-r94725453119e4003af336d7294984085.service - /usr/bin/sleep 300
     Loaded: loaded (/run/systemd/transient/run-r94725453119e4003af336d7294984085.service; transient)
  Transient: yes
     Active: active (running) since Wed 2021-06-09 11:50:10 AEST; 11s ago
   Main PID: 11517 (sleep)
      Tasks: 1 (limit: 2325)
     Memory: 184.0K
        CPU: 4ms
     CGroup: /system.slice/run-r94725453119e4003af336d7294984085.service
             └─11517 /usr/bin/sleep 300

Jun 09 11:50:10 f33-1.ipa.local systemd[1]: Started /usr/bin/sleep 300.

% ls -nld /sys/fs/cgroup/system.slice/run-r94725453119e4003af336d7294984085.service
drwxr-xr-x. 2 0 0 0 Jun  9 11:50 /sys/fs/cgroup/system.slice/run-r94725453119e4003af336d7294984085.service

% ps -o uid,pid,cmd --pid 11517
  UID     PID CMD
 1000   11517 /usr/bin/sleep 300
```

The process is running as user `1000`, but the cgroup is owned by
`root`.

### Specify `Delegate=true`

We need to specify `Delegate=true` to tell systemd to delegate the
cgroup to the specified `User`:

```shell
% sudo systemd-run -p Delegate=true -p User=1000 sleep 300
Running as unit: run-r518dbc963502423c9c67b1c72d3d4c12.service

% systemctl status run-r518dbc963502423c9c67b1c72d3d4c12.service
● run-r518dbc963502423c9c67b1c72d3d4c12.service - /usr/bin/sleep 300
     Loaded: loaded (/run/systemd/transient/run-r518dbc963502423c9c67b1c72d3d4c12.service; transient)
  Transient: yes
     Active: active (running) since Wed 2021-06-09 11:59:34 AEST; 1min 21s ago
   Main PID: 11579 (sleep)
      Tasks: 1 (limit: 2325)
     Memory: 184.0K
        CPU: 3ms
     CGroup: /system.slice/run-r518dbc963502423c9c67b1c72d3d4c12.service
             └─11579 /usr/bin/sleep 300

Jun 09 11:59:34 f33-1.ipa.local systemd[1]: Started /usr/bin/sleep 300.

% ls -nld /sys/fs/cgroup/system.slice/run-r518dbc963502423c9c67b1c72d3d4c12.service
drwxr-xr-x. 2 1000 1000 0 Jun  9 11:59 /sys/fs/cgroup/system.slice/run-r518dbc963502423c9c67b1c72d3d4c12.service
```

systemd `chown()`ed the cgroup to the specified `User`.  Note that
very few of the cgroup controls in the cgroup directory are
writable by user `1000`:

```shell
% ls -nl /sys/fs/cgroup/system.slice/run-r518dbc963502423c9c67b1c72d3d4c12.service \
    |grep 1000 
-rw-r--r--. 1 1000 1000 0 Jun  9 11:59 cgroup.procs
-rw-r--r--. 1 1000 1000 0 Jun  9 11:59 cgroup.subtree_control
-rw-r--r--. 1 1000 1000 0 Jun  9 11:59 cgroup.threads
```

So the process cannot adjust its root cgroup's `memory.max`,
`pids.max`, `cpu.weight` and so on.  It *can* create cgroup
subtrees, manage resources within them, and move processes and
threads among those subtrees and its root cgroup.

### Arbitrary UIDs

So far I have specified `User=1000`.  User `1000` is a "known user".
That is, the Name Service Switch (see `nss(5)`) returns information
about the user (name, home directory, shell, etc):

```shell
% getent passwd $(id -u)
ftweedal:x:1000:1000:ftweedal:/home/ftweedal:/bin/zsh
```

However, when executing containers with user namespaces, we usually
map the namespace UIDs to unprivileged host UIDs from a *subordinate
ID* range.  Subordinate UIDs and GID ranges are currently defined in
`/etc/subuid` and `/etc/subgid` respectively.  The subuid range for
user `1000` is:

```shell
% grep $(id -un) /etc/subuid
ftweedal:100000:65536
```

User `1000` has been allocated the range `100000`–`165535`.  So
let's try `systemd-run` with `User=100000`:

```shell
% sudo systemd-run -p Delegate=true -p User=100000 sleep 300
Running as unit: run-r1498304af7df406c9698da5c683ea79e.service

% systemctl --no-pager --full status run-r1498304af7df406c9698da5c683ea79e.service
× run-r1498304af7df406c9698da5c683ea79e.service - /usr/bin/sleep 300
     Loaded: loaded (/run/systemd/transient/run-r1498304af7df406c9698da5c683ea79e.service; transient)
  Transient: yes
     Active: failed (Result: exit-code) since Wed 2021-06-09 12:32:43 AEST; 14s ago
    Process: 11766 ExecStart=/usr/bin/sleep 300 (code=exited, status=217/USER)
   Main PID: 11766 (code=exited, status=217/USER)
        CPU: 2ms

Jun 09 12:32:43 f33-1.ipa.local systemd[1]: Started /usr/bin/sleep 300.
Jun 09 12:32:43 f33-1.ipa.local systemd[11766]: run-r1498304af7df406c9698da5c683ea79e.service: Failed to determine user credentials: No such process
Jun 09 12:32:43 f33-1.ipa.local systemd[11766]: run-r1498304af7df406c9698da5c683ea79e.service: Failed at step USER spawning /usr/bin/sleep: No such process
Jun 09 12:32:43 f33-1.ipa.local systemd[1]: run-r1498304af7df406c9698da5c683ea79e.service: Main process exited, code=exited, status=217/USER
Jun 09 12:32:43 f33-1.ipa.local systemd[1]: run-r1498304af7df406c9698da5c683ea79e.service: Failed with result 'exit-code'.
```

It failed.  Cutting the noise, the cause is:

```
Failed to determine user credentials: No such process
```

The string `No such process` is a bit misleading.  It is the string
associated with the `ESRCH` error value (see `errno(3)`).  Here it
indicates that `getpwuid(3)` did not find a user record for uid
`100000`.  systemd unconditionally fails in this scenario.  And this
is a problem for us because without intervention, subordinate UIDs
do not have associated user records.

### Arbitrary UIDs (with `passwd` entry)

So let's make NSS return something for user `100000`.  There are
several ways we could do this, including adding it to `/etc/passwd`,
or creating an NSS module that generates passwd records for ranges
declared in `/etc/subuid`.

Another way is to use [systemd's NSS module][nss-systemd], which
returns passwd records for containers created by
[`systemd-machined`][systemd-machined].  And that's what I did.
Given the root filesystem for a container in `./rootfs`,
[`systemd-nspawn`][systemd-nspawn] creates the container.  The
`--private-users=100000` option tells it to create a user namespace
mapping to the host UID `100000` with default size 65536:

```shell
% sudo systemd-nspawn --directory rootfs --private-users=100000 /bin/sh
Spawning container rootfs on /home/ftweedal/go/src/github.com/opencontainers/runc/rootfs.
Press ^] three times within 1s to kill container.
Selected user namespace base 100000 and range 65536.
sh-5.0#
```

On the host we can see the "machine" via
[`machinectl(1)`][machinectl].  We also observe that NSS now returns
results for UIDs in the mapped host range.

```shell
% getent passwd 100000 165535  
vu-rootfs-0:x:100000:65534:UID 0 of Container rootfs:/:/usr/sbin/nologin

% getent passwd 100000 165534
vu-rootfs-0:x:100000:65534:UID 0 of Container rootfs:/:/usr/sbin/nologin
vu-rootfs-65534:x:165534:65534:UID 65534 of Container rootfs:/:/usr/sbin/nologin
```

The `passwd` records are constructed on demand by
[`nss-systemd(8)`][nss-systemd] using data registered by
`systemd-machined`.

[nss-systemd]: https://www.freedesktop.org/software/systemd/man/nss-systemd.html
[systemd-machined]: https://www.freedesktop.org/software/systemd/man/systemd-machined.html
[systemd-nspawn]: https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html
[machinectl]: https://www.freedesktop.org/software/systemd/man/machinectl.html

Now let's try `systemd-run` again:

```shell
% sudo systemd-run -p Delegate=true -p User=100000 sleep 300
Running as unit: run-r076a82c36fcd4934b13bba47fcc8462e.service

% systemctl status run-r076a82c36fcd4934b13bba47fcc8462e.service
● run-r076a82c36fcd4934b13bba47fcc8462e.service - /usr/bin/sleep 300
     Loaded: loaded (/run/systemd/transient/run-r076a82c36fcd4934b13bba47fcc8462e.service; transient)
  Transient: yes
     Active: active (running) since Wed 2021-06-09 14:14:34 AEST; 11s ago
   Main PID: 12045 (sleep)
      Tasks: 1 (limit: 2325)
     Memory: 180.0K
        CPU: 4ms
     CGroup: /system.slice/run-r076a82c36fcd4934b13bba47fcc8462e.service
             └─12045 /usr/bin/sleep 300

Jun 09 14:14:34 f33-1.ipa.local systemd[1]: Started /usr/bin/sleep 300.

% ls -nld /sys/fs/cgroup/system.slice/run-r076a82c36fcd4934b13bba47fcc8462e.service 
drwxr-xr-x. 2 100000 65534 0 Jun  9 14:14 /sys/fs/cgroup/system.slice/run-r076a82c36fcd4934b13bba47fcc8462e.service

% ps -o uid,gid,pid,cmd --pid 12045
  UID   GID     PID CMD
  100000 65534  12045 /usr/bin/sleep 300

% id -un 65534
nobody
```

Now the cgroup is owned by `100000`.  But the group ID (`gid`) under
which the process runs, and the group owner of the cgroup, is
`65534`.  This is the host's `nobody` account.

### Specify `Group=`

In a user-namespaced container, ordinarily you would want both the
user *and* the group of the container process to be mapped into the
user namespace.  Likewise, you would expect the cgroup to be owned
by a known (in the namespace) user.  Setting the `Group=` property
should achieve this.

```shell
% sudo systemd-run -p Delegate=true -p User=100000 -p Group=100000 sleep 300      
Running as unit: run-re610d14cc0584a37a3d4099268df75d8.service

% systemctl status run-re610d14cc0584a37a3d4099268df75d8.service
● run-re610d14cc0584a37a3d4099268df75d8.service - /usr/bin/sleep 300
     Loaded: loaded (/run/systemd/transient/run-re610d14cc0584a37a3d4099268df75d8.service; transient)
  Transient: yes
     Active: active (running) since Wed 2021-06-09 14:24:58 AEST; 7s ago
   Main PID: 12131 (sleep)
      Tasks: 1 (limit: 2325)
     Memory: 184.0K
        CPU: 5ms
     CGroup: /system.slice/run-re610d14cc0584a37a3d4099268df75d8.service
             └─12131 /usr/bin/sleep 300

Jun 09 14:24:58 f33-1.ipa.local systemd[1]: Started /usr/bin/sleep 300.

% ls -nld /sys/fs/cgroup/system.slice/run-re610d14cc0584a37a3d4099268df75d8.service
drwxr-xr-x. 2 100000 100000 0 Jun  9 14:24 /sys/fs/cgroup/system.slice/run-re610d14cc0584a37a3d4099268df75d8.service

% ps -o uid,gid,pid,cmd --pid 12131
  UID   GID     PID CMD
100000 100000 12131 /usr/bin/sleep 300
```

Finally, systemd is exhibiting the behaviour we desire.


## Discussion and next steps

In summary, the findings from this investigation are:

- systemd changes the cgroup ownership of transient units according
  to the `User=` and `Group=` properties, if and only if
  `Delegate=true`.

- systemd currently requires `User=` and `Group=` to refer to known
  (via NSS) users and groups.

- Unprivileged user systemd service manager instances lack the
  privileges to set supplementary groups for the container process.
  This is not a problem for the OpenShift use case, because it uses
  the system service manager.

As to the second point, I am curious why systemd behaves this way.
It does makes sense to query NSS to find out the shell, home
directory, and login name for setting up the execution environment.
But if there is no `passwd` record, why not synthesise one with
conservative defaults?  Running processes as anonymous UIDs has a
valid use case—increasingly so, as adoption of user namespaces
increases.  I [filed an RFE (systemd#19781)][systemd#19781] against
systemd to suggest relaxing this restriction, and inquire whether
this is a Bad Idea for some reason I don't yet understand.

There are some alternative approaches that don't require changing
systemd:

- Use `systemd-machined` to register a machine.  It provides the
  `org.freedesktop.machine1.Manager.RegisterMachine` D-Bus method
  for this purpose.  But `systemd-machined` is not used (or even
  present) on OpenShift cluster nodes.

- Implement, ship and configure an NSS module that synthesises
  `passwd` records for user subordinate ID ranges.  The *shadow*
  project has [defined an NSS interface][shadow#321] for subid
  ranges.  *libsubid*, part of *shadow*, will provide abstract subid
  range lookups (forward and reverse).  So a *libsubid*-based
  solution to this should be possible.  Unfortunately, *libsubid* is
  not yet widely available as a shared library.

  As an example, synthetic user records could have a username like
  `subuid-{username}-{uid}`.  The home directory and shell would be
  `/` and `/sbin/nologin`, like the records synthesised by
  `nss-systemd`.

- Update the container runtime (`runc`) to `chown` the cgroup *after
  systemd creates it*.  In fact, this is what `systemd-nspawn` does.
  This approach is nice because the only component to change is
  `runc`—which had to change anyway, to add the logic to determine
  the cgroup owner UID.  To the best of my knowledge, on OpenShift
  `runc` gets executed as `root` (on the node), so it should have
  the permissions required to do this.  Unless SELinux prevents it.

Of these three options, modifying `runc` to `chown` the cgroup
directory seems the most promising.  While I wait for feedback on
[systemd#19781][], I will start hacking on `runc` and testing my
modifications.

[systemd#19781]: https://github.com/systemd/systemd/issues/19781
[shadow#321]: https://github.com/shadow-maint/shadow/pull/321

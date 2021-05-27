---
tags: containers, cgroups
---

# Using `runc` to explore the OCI Runtime Specification

In recent posts I explored how to use user namespaces and cgroups v2
on OpenShift.  My main objective is to run *systemd*-based workloads
in user namespaces that map to unprivileged users on the host.  This
is a prerequisite to running [FreeIPA][] *securely* in OpenShift,
and supporting multitenancy.

[FreeIPA]: https://www.freeipa.org/page/Main_Page

Independently, user namespaces and cgroups v2 already work well in
OpenShift.  But for *systemd* support there is a critical gap: the
pod's cgroup directory (mounted as `/sys/fs/cgroup/` in the
container) is owned by `root`—the *host's* UID 0, which is unmapped
in the pod's user namespace.  As a consequence, the container's main
process (`/sbin/init`, which is *systemd*) cannot manage cgroups,
and terminates.

To understand how to close this gap, I needed to become familiar
with the low-level container runtime behaviour.  This post discusses
the relationship between various container runtime components and
demonstrates how to use `runc` directly to create and run
containers.  I also outline some possible approaches to solving the
cgroup ownership issue.

## Podman, Kubernetes, CRI, CRI-O, runc, oh my!

What actually happens when you "run a container".  Abstractly, a
container runtime sets up a *sandbox* and runs a process in it.  The
sandbox consists of a set of namespaces (PID, UTS, mount, cgroup,
user, network, etc), and a restricted view of a filesystem (via
`chroot(2)` or similar mechanism).

There are several different container runtimes in widespread use.
In fact, there are several different *layers* of container runtime
with different purposes:

- End-user focused container runtimes include [*Podman*][podman] and
  *Docker*.

- Kubernetes defines the [Container Runtime Interface (CRI)][CRI],
  which it uses to run containers.  Compliant implementations
  include *containerd* and [*CRI-O*][CRI-O].

- The *Open Container Initiative (OCI)* [runtime spec][] defines a
  low-level container runtime interface.  Implementations include
  [`runc`][runc] and [*crun*][crun].  OCI runtimes are designed to
  be used by higher-level container runtimes.  They are not friendly
  for humans to use directly.

[podman]: https://podman.io/
[CRI]: https://github.com/kubernetes/community/blob/master/contributors/devel/sig-node/container-runtime-interface.md
[CRI-O]: https://github.com/cri-o/cri-o
[runtime spec]: https://github.com/opencontainers/runtime-spec
[runc]: https://github.com/opencontainers/runc
[crun]: https://github.com/containers/crun

Running a container usually involves a higher-level runtime *and* a
low-level runtime.  For example, Podman uses an OCI runtime; crun by
default on Fedora but `runc` works fine too.  OpenShift (which is
built on Kubernetes) uses CRI-O, which in turn uses `runc` (CRI-O
itself can use any OCI runtime).

### Division of responsibilities

So, what are responsibilities of the higher-level runtime compared
to the OCI (or other low-level) runtime?  In general the high-level
runtime is responsible for:

- Image management (pulling layers, preparing overlay filesystem)

- Determining the mounts, environment, namespaces, resource limits
  and security policies for the container

- Network setup for the container

- Metrics, accounting, etc.

The steps performed by the low-level runtime include:

- Create and and enter required namespaces

- `chroot(2)` (or `pivot_root(2)`) to the specified root filesystem
  path

- Create requested mounts

- Create cgroups and apply resource limits

- Adjust capabilities and apply seccomp policy

- Execute the container's main process

::: note

I mentioned several features specific to Linux in the list above.
The OCI Runtime Specification also specifies Windows, Solaris and
VM-based workloads.  This post assumes a Linux workload, so many
details are Linux-specific.

:::

The above list is just a rough guide and not absolute.  Depending on
use case the high-level runtime might perform some of the low-level
steps.  For example, if container networking is required, Podman
might create the network namespace, setting up devices and routing.
Then, instead of asking the OCI runtime to create a network
namespace, it tells the runtime to enter the existing namespace.


## Running containers via `runc`

Because our effort is targeting OpenShift, the rest of this post
mainly deals with `runc`.

::: note

The functions demonstrated in this post were performed using `runc`
version 1.0.0-rc95+dev, which I built from source (commit
`19d75e1c`).  The Fedora 33 and 34 repositories offer `runc` version
1.0.0-rc93, which **does not work**.

:::

### Clone and build

Install the Go compiler and *libseccomp* development headers:

```shell
% sudo dnf -y --quiet install libseccomp-devel

Installed:
  golang-1.16.3-1.fc34.x86_64
  golang-bin-1.16.3-1.fc34.x86_64
  golang-src-1.16.3-1.fc34.noarch
  libseccomp-devel-2.5.0-4.fc34.x86_64
```

Clone the `runc` source code and build the program:

```shell
% mkdir -p ~/go/src/github.com/opencontainers
% cd ~/go/src/github.com/opencontainers
% git clone --quiet https://github.com/opencontainers/runc
% cd runc
% make --quiet
% ./runc --version
runc version 1.0.0-rc95+dev
commit: v1.0.0-rc95-31-g19d75e1c
spec: 1.0.2-dev
go: go1.16.3
libseccomp: 2.5.0
```

### Prepare root filesystem

I want to create a filesystem from my *systemd* based
[`test-nginx`][image-test-nginx] container image.  To avoid
configuring overlay filesystems myself, I used Podman to create a
container, then exported the whole container filesystem, via
`tar(1)`, to a local directory:

```shell
% podman create --quiet quay.io/ftweedal/test-nginx
e97930b3e6f7ef3879c5b4e21874fb83a95afa8f224ebfb07d96c0b2a6c7cd1f
% mkdir
rootfs
% podman export e97930b3 | tar -xC rootfs
% ls rootfs
bin   dev  home  lib64       media  opt   root  sbin  sys  usr
boot  etc  lib   lost+found  mnt    proc  run   srv   tmp  var
```

[image-test-nginx]: https://quay.io/repository/ftweedal/test-nginx

### Create `config.json`

OCI runtimes read the container configuration from `config.json` in
the *bundle* directory.  (`runc` uses the current directory as the
default bundle directory).  The `runc spec` command generates a
sample `config.json` which can serve as a starting point:

```shell
% ./runc spec --rootless
% file config.json
config.json: JSON data
% jq -c .process.args < config.json
["sh"]
```

We can see that `runc` created the sample config.  The command to
execute is `sh(1)`.  Let's change that to `/sbin/init`:

```shell
% mv config.json config.json.orig
% jq '.process.args=["/sbin/init"]' config.json.orig > config.json
```

::: notes

`jq(1)` cannot operate on JSON files in situ, so you first have to
copy or move the input file.  The [`sponge(1)`][sponge-man] command,
provided by the *moreutils* package, offers an alternative approach.

:::

[sponge-man]: https://linux.die.net/man/1/sponge

### Run container

Now we can try and run the container:

```shell
% ./runc --systemd-cgroup run test
Mount failed for selinuxfs on /sys/fs/selinux:  No such file or directory
Another IMA custom policy has already been loaded, ignoring: Permission denied
Failed to mount tmpfs at /run: Operation not permitted
[!!!!!!] Failed to mount API filesystems.
Freezing execution.
```

That didn't work.  systemd failed to mount a `tmpfs` (temporary,
memory-based filesystem) at `/tmp`, and halted.  The container
itself was still running (but frozen).  I was able to kill it from
another terminal:

```shell
% ./runc list --quiet
test
% ./runc kill test KILL
% ./runc list --quiet
```

It turned out that in addition to the process to run, the config
requires several changes to successfully run a *systemd*-based
container.  I will not repeat the whole process here, but I achieved
a working config through a combination of trial-and-error, and
comparison against OCI configurations produced by Podman.  The
following [`jq(1)`][jq] program performs the required modifications:

``` {.json .numberLines}
.process.args = ["/sbin/init"]
| .process.env |= . + ["container=oci"]
| [{"containerID":1,"hostID":100000,"size":65536}] as $idmap
| .linux.uidMappings |= . + $idmap
| .linux.gidMappings |= . + $idmap
| .linux.cgroupsPath = "user.slice:runc:test"
| .linux.namespaces |= . + [{"type":"network"}]
| .process.capabilities[] =
  [ "CAP_CHOWN", "CAP_FOWNER", "CAP_SETUID", "CAP_SETGID",
    "CAP_SETPCAP", "CAP_NET_BIND_SERVICE" ]
| {"type": "tmpfs",
   "source": "tmpfs",
   "options": ["rw","rprivate","nosuid","nodev","tmpcopyup"]
  } as $tmpfs
| .mounts |= [{"destination":"/var/log"} + $tmpfs] + .
| .mounts |= [{"destination":"/tmp"} + $tmpfs] + .
| .mounts |= [{"destination":"/run"} + $tmpfs] + .
```

[jq]: https://stedolan.github.io/jq/manual/

This program performs the following actions:

- Set the container process to "/sbin/init" (*systemd*).

- Set the `$container` environment variable as [required by
  systemd](https://systemd.io/CONTAINER_INTERFACE/#environment-variables).

- Add UID mappings for UIDs `1`–`65536` in the container's user
  namespace.  The host range (started at `100000`) is taken from my
  user account's assigned range in `/etc/subuid`.  **You may need a
  different number.**  The mapping for the container's UID `0` to my
  user account already exists in the config.

- Set the container's cgroup path.  A non-absolute path is
  interpreted relative to a runtime-determined location.

- Request the runtime to create a network namespace.  Without this,
  the container will have no network stack and *nginx* won't run.

- Set the [capabilities][] required by the container.  *systemd*
  requires all of these capabilities, although
  `CAP_NET_BIND_SERVICE` is only required for network name
  resolution (*systemd-resolved*). And *nginx*.

- Tell the runtime to mount `tmpfs` filesystems at `/run`, `/tmp`
  and `/var/log`.

[capabilities]: https://linux.die.net/man/7/capabilities

I ran the program to modify the config, then started the container:

```shell
% jq --from-file filter.jq config.json.orig > config.json
% ./runc --systemd-cgroup run test
systemd v246.10-1.fc33 running in system mode. (+PAM …
Detected virtualization container-other.
Detected architecture x86-64.

Welcome to Fedora 33 (Container Image)!

…

[  OK  ] Started The nginx HTTP and reverse proxy server.
[  OK  ] Reached target Multi-User System.
[  OK  ] Reached target Graphical Interface.
         Starting Update UTMP about System Runlevel Changes...
[  OK  ] Finished Update UTMP about System Runlevel Changes.

Fedora 33 (Container Image)
Kernel 5.11.17-300.fc34.x86_64 on an x86_64 (console)

runc login:
```

OK!  *systemd* initialised the system properly and started *nginx*.
We can confirm *nginx* is running properly by running `curl` in the
container:

```shell
% ./runc exec test curl --silent --head localhost:80
HTTP/1.1 200 OK
Server: nginx/1.18.0
Date: Thu, 27 May 2021 02:29:58 GMT
Content-Type: text/html
Content-Length: 5564
Last-Modified: Mon, 27 Jul 2020 22:20:49 GMT
Connection: keep-alive
ETag: "5f1f5341-15bc"
Accept-Ranges: bytes
```

At this point we cannot access *nginx* from outside the container.
That's fine; I don't need to work out how to do that.  Not today,
anyhow.

## How `runc` creates cgroups

`runc` manages container cgroups via the host's *systemd* service.
Specifically, it communicates with *systemd* over DBus to create a
[transient scope][transient] for the container.  Then it binds the
container cgroup namespace to this new scope.

Observe that the inode of `/sys/fs/cgroup/` in the container is the
same as the scope created for the container by *systemd* on the
host:

```shell
% ./runc exec test ls -aldi /sys/fs/cgroup
64977 drwxr-xr-x. 5 root root 0 May 27 02:26 /sys/fs/cgroup

% ls -aldi /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/user.slice/runc-test.scope 
64977 drwxr-xr-x. 5 ftweedal ftweedal 0 May 27 12:26 /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/user.slice/runc-test.scope
```

The mapping of `root` in the container's user namespace to
`ftweedal` is confirmed by the UID map of the container process:

```shell
% ./runc list -f json | jq '.[]|select(.id="test").pid'
186718

% cat /proc/186718/uid_map
         0       1000          1
         1     100000      65536

% id --user ftweedal
1000
```

## Next steps

*systemd* is running properly in the container, but `root` in the
container is mapped to my main user account.  The container is not
as isolated as I would like it to be.  A partial sandbox escape
could lead to the containerised process(es) messing with local
files, or other processes owned by my user (including other
containers).

User-namespaced containers in OpenShift (via CRI-O annotations) are
allocated non-overlapping host ID ranges.  All the host IDs are
essentially anonymous.  I confirmed this in [an earlier blog
post](2021-03-10-openshift-user-namespace-multi-user.html).  That is
good!  But the container's cgroup is owned by the *host's* UID 0,
which is unmapped in the container.  *systemd*-based workloads
cannot run because the container cannot write to its cgroupfs.

Therefore, the next steps in my investigation are:

1. Alter the ID mappings to use a single mapping of only "anonymous"
   users.  This is a simple change to the OCI config.  The host IDs
   still have to come from the user's allocated sub-ID range.

2. Find (or implement) a way to change the ownership of the
   container's cgroup scope to the **container's** UID 0.

When using the *systemd* cgroup manager, `runc` uses the [*transient
unit API*][transient] to ask *systemd* to create a new scope for the
container.  I am still learning about this API.  Perhaps there is a
way to specify a different ownership for the new scope or service.
If so, we should be able to avoid changes to higher-level container
runtimes like CRI-O.  That would be the best outcome.

[transient]: https://www.freedesktop.org/wiki/Software/systemd/ControlGroupInterface/

Otherwise, I will investigate whether we could use the OCI
`createRuntime` hook to `chown(2)` the container's cgroup scope.
Unfortunately, the semantics of `createRuntime` is currently
underspecified.  The specification is ambiguous about whether the
containers cgroup scope exists when this hook is executed.  If this
approach is valid, we will have to update CRI-O to add the relevant
hook command to the OCI config.

Another possible approach is for the high-level runtime to perform
the ownership change itself.  This would be done after it invokes
the OCI runtime's `create` command, but before it invokes `start`.
(See also the OCI [container lifecycle description][]).  However, on
OpenShift CRI-O runs as user `containers` and the container's cgroup
scope is owned by `root`.  So I have doubts about the viability of
this approach, as well as the OCI hook approach.

[container lifecycle description]: https://github.com/opencontainers/runtime-spec/blob/master/runtime.md#lifecycle

Whatever the outcome, there will certainly be more blog posts as I
continue this long-running investigation.  I still have much to
learn as I struggle towards the goal of systemd-based workloads
running securely on OpenShift.

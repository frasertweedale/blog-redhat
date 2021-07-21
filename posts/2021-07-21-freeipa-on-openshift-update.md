---
tags: openshift, freeipa, containers
---

# FreeIPA on OpenShift: July 2021 update

Over the last year I've done a lot of investigations into OpenShift,
and container runtimes more generally.  The driver of this work is
the FreeIPA on OpenShift project (known within Red Hat as IDMOCP).
I published the results of my investigations in numerous blog posts,
but I have not yet written much about *why* we are doing this at
all.

So it's time to fix that.  In this short post I discuss why we want
FreeIPA on OpenShift, and the major decision that put us on our
current implementation path.

FreeIPA is a centralised identity management system for the
enterprise.  You enrol users, hosts and services, and configure
access policies and other security mechanisms.  The system provides
authentication and policy enforcement mechanisms.  It is similar to
Microsoft Active Directory (and indeed can integrate with AD).
FreeIPA is a complex system with lots of components including:

- LDAP server (389 DS / RHDS)
- Kerberos KDC (MIT Kerberos)
- Certificate authority (Dogtag / RHCS)
- HTTP API (Apache httpd and a lot of Python code)
- Host client daemon (SSSD)
- several smaller supporting services
- installation and administration tools

FreeIPA is available on Fedora and RHEL.  You install the RPMs and
the installation program configures the system.  It is intended to
be deployed on a dedicated machine (VM or bare metal).

We are motivated to support FreeIPA on OpenShift for several
reasons, including:

- Easily providing identity services to applications running on
  OpenShift.

- Leveraging OpenShift and Kubernetes orchestration, scalaing and
  management features to improve robustness and reduce management
  overhead of FreeIPA deployments.

- Offering FreeIPA, hosted on OpenShift, as a managed service.

Understandably, moving such an application to OpenShift is a
non-trivial task.  At the beginning of this effort, we had to decide
the main implementation approach.  There were three options:

1. Put the whole system in a single "monolithic container", with
   systemd as the init process.  At the time (and still today)
   OpenShift only supports running systemd workloads in privileged
   containers, which is not acceptable.  The runtime needs to evolve
   to support this use case.  Work on *some* of the missing features
   (such as user namespaces and cgroups v2) was already underway.

2. Deploy different parts of the FreeIPA system in different
   containers, running unprivileged.  This is a fundamental shift
   from the current architecture and a huge up-front engineering
   effort.  Also, the current architecture has to be maintained and
   supported for a long time (>10 years).  So this approach brings
   a substantial ongoing cost in maintaining two architectures of
   the same application.  On a technical level, this approach is
   feasible today.

3. Use a VM-based workload (Kata / OpenShift Sandboxed Containers).
   This option probably has the lowest up-front and ongoing
   engineering costs.  But it requires a bare metal cluster or
   nested virtualisation, which is not available from most cloud
   providers.  By extension, [OpenShift Dedicated (OSD)][OSD] also
   does not supported it.  Red Hat managed services run on OSD.
   Offering a managed service is one of the motivators of our
   effort.  So at this time, VM-based workloads are not an option
   for us.

[OSD]: https://www.openshift.com/products/dedicated/

As a small team, and considering the business reality of the
existing offering as part of RHEL, we decided to pursue the
"monolithic container" approach.  We are depending on the OpenShift
runtime evolving to a point where it can support fully isolated
systemd-based workloads.  And that is why I have invested much of
the last 12 months in understanding container runtimes and pushing
their limits.

Our approach is not "cloud native" and indeed many people have
expressed alarm or confusion when we tell them what we are doing.
Certainly, if we were designing FreeIPA from the ground up in
today's world, it would look very different from the current
architecture.  But this is the reality: if you want customers to
bring their mature, complex applications onto OpenShift, don't
expect them to spend big money and assume big risk to rearchitect
the application to fit the new environment.

What customers actually need is to be able to bring the application
across more or less as-is.  Then they can realise the benefits
(automation, monitoring, scaling, etc) *incrementally*, with lower
up-front costs and less risk.

If my claims are correct, then proper systemd workload support in
OpenShift will be a Very Big Deal.  But even if I'm wrong, it is
still critical for our FreeIPA on OpenShift effort.  And it is
achievable.  In my next post I'll demonstrate my working proof of
concept for user-namespaced systemd workloads on OpenShift.

---
tags: dogtag, profiles
---

..
  Copyright 2014 Red Hat, Inc.

  This work is licensed under a
  Creative Commons Attribution 4.0 International License.

  You should have received a copy of the license along with this
  work. If not, see <http://creativecommons.org/licenses/by/4.0/>.


Dogtag profile definitions
==========================

In the `previous post`_ I began an exploration of Dogtag's
*certificate profiles* feature by looking at the certificate request
process and the relationship between PKCS #10 CSRs and Dogtag
certificate enrolment requests, which are used to submit CSRs in the
context of a *profile*.  In this post we will look at how Dogtag
profiles are defined and learn a little about how Dogtag uses them
in the certificate enrolment process.

.. _Previous post: 2014-05-12-dogtag-profiles-cert-requests.html

Each instance of Dogtag or Certificate Server starts out with a
default set of profiles; these are found in the Dogtag instance
directory in ``/var/lib/pki/<instance-name>/ca/profiles/ca/``.
There are dozens of profiles but since we are already familiar with
``caServerCert`` let's open up ``caServerCert.cfg`` and have a
look::

  desc=This certificate profile is for enrolling server certificates.
  visible=true
  enable=true
  enableBy=admin
  auth.class_id=
  name=Manual Server Certificate Enrollment
  input.list=i1,i2
  input.i1.class_id=certReqInputImpl
  input.i2.class_id=submitterInfoInputImpl
  output.list=o1
  output.o1.class_id=certOutputImpl
  policyset.list=serverCertSet
  policyset.serverCertSet.list=1,2,3,4,5,6,7,8
  policyset.serverCertSet.1.constraint.class_id=subjectNameConstraintImpl
  policyset.serverCertSet.1.constraint.name=Subject Name Constraint
  policyset.serverCertSet.1.constraint.params.pattern=.*CN=.*
  policyset.serverCertSet.1.constraint.params.accept=true
  policyset.serverCertSet.1.default.class_id=userSubjectNameDefaultImpl
  policyset.serverCertSet.1.default.name=Subject Name Default
  policyset.serverCertSet.1.default.params.name=
  policyset.serverCertSet.2.constraint.class_id=validityConstraintImpl
  policyset.serverCertSet.2.constraint.name=Validity Constraint
  policyset.serverCertSet.2.constraint.params.range=720
  policyset.serverCertSet.2.constraint.params.notBeforeCheck=false
  policyset.serverCertSet.2.constraint.params.notAfterCheck=false
  policyset.serverCertSet.2.default.class_id=validityDefaultImpl
  policyset.serverCertSet.2.default.name=Validity Default
  policyset.serverCertSet.2.default.params.range=720
  policyset.serverCertSet.2.default.params.startTime=0
  policyset.serverCertSet.3.constraint.class_id=keyConstraintImpl
  policyset.serverCertSet.3.constraint.name=Key Constraint
  policyset.serverCertSet.3.constraint.params.keyType=-
  policyset.serverCertSet.3.constraint.params.keyParameters=1024,2048,3072,4096,nistp256,nistp384,nistp521
  policyset.serverCertSet.3.default.class_id=userKeyDefaultImpl
  policyset.serverCertSet.3.default.name=Key Default
  ... (on it goes, through to policyset.serverCertSet.8.*)

There is an obvious relationship between the profile configuration,
the certificate enrolment request template retrieved via ``pki
cert-request-profile-show`` and the behaviour of the CA when
submitting or approving enrolment requests.  For example, there are
two inputs: one for a certificate request (PKCS #10 CSR) and one for
submitter information.  These are the same two inputs we had to fill
out in the XML certificate enrolment request template.  And there
are constraint declarations; again, we have observed the effects of
these declarations when non-conformant enrolment requests were
rejected.

Let's break down the profile configuration.  The top-level settings
such as ``name``, ``desc`` and ``enable`` are self-explanatory.
Moving down, we see the ``input.list`` key specifying the list
``i1,i2``, followed by keys ``input.i1.class_id`` and
``input.i2.class_id``.  This pattern of ``foo.list=f1,f2,..``
followed by ``foo.f1...``, ``foo.f2...``, and so on also occurs
further down for ``output`` and ``policyset``, and seems to provide
a simple, deterministic way to read ordered declarations from the
profile configuration.

The ``class_id`` key also occurs in the output and policy set
contexts.  To what does its value refer?  The file
``/etc/pki/<instance-name>/ca/registry.cfg`` holds the answer,
mapping the values in the profile configuration to Java classes.
These classes implement interfaces relevant to their role in the
profile system: ``IProfileInput``, ``IProfileOutput``,
``IPolicyConstraint`` for inputs, outputs and policy constraints,
and ``IPolicyDefault`` *and* ``ICertInfoPolicyDefault`` for policy
defaults.

Whilst inputs and outputs have no further configuration beyond the
``class_id``, policy set constraints and defaults are parameterised,
with each class offering named parameters that relate to its
function.  For example, ``subjectNameConstraintImpl`` has parameters
``pattern`` (a regular expression) and ``accept`` (boolean; I infer
that this controls whether to accept or reject a CSR on match).
When a profile is used, e.g. to generate an enrolment request
template, submit an enrolment request, or to generate a certificate,
Dogtag instantiates the classes according to the profile
configuration and uses their behaviours to carry out the requested
action - or to decide how or whether to carry it out.

Armed with an understanding of how profiles are configured, let's
try and define a *new* profile.  My first action was to simply copy
``caServerCert.cfg`` to ``caServerCertTest.cfg`` (ensuring the new
file can be read by ``pkiuser``).  The ``name`` and ``desc`` values
were changed and the subject name constraint pattern was updated to
``.*CN=test.*`` to make it easy to verify that the new profile is
being used correctly.  Let's restart the server (the service name
depends on the Dogtag instance name) and see if Dogtag has learned
about the new profile::

  $ sudo systemctl restart pki-tomcatd@pki-tomcat.service
  $ pki cert-request-profile-show caServerCertTest
  BadRequestException: Cannot provide enrollment template for profile `caServerCertTest`.  Profile not found

There must be more to configure.  A thorough search turns up a few
references to ``caServerCert`` in
``/etc/pki/<instance-name>/ca/CS.cfg``::

  ...
  profile.caServerCert.class_id=caEnrollImpl
  profile.caServerCert.config=/var/lib/pki/<instance-name>/ca/profiles/ca/caServerCert.cfg
  ...
  profile.list=caUserCert,caECUserCert,...,caServerCert,...
  ...

We have found what appears to be the canonical list of profiles and
furthermore can see that the full path to the profile is
configurable and that each profile specifies a ``class_id``.  The
``class_id`` values that can be used here appear in the same
``registry.cfg`` we learned about above.  The classes referred to
implement the ``IProfile`` interface.

After adding the ``profile.caServerCertTest`` configuration,
appending ``caServerCertTest`` to ``profile.list`` and restarting
Dogtag again, we can finally use our new profile::

  $ pki cert-request-profile-show caServerCertTest
  --------------------------------------------------
  Enrollment Template for Profile "caServerCertTest"
  --------------------------------------------------
    Profile ID: caServerCertTest
    Renewal: false

    Input ID: i1
    Name: Certificate Request Input
    Class: certReqInputImpl

      Attribute Name: cert_request_type
      Attribute Description: Certificate Request Type
      Attribute Syntax: cert_request_type

      Attribute Name: cert_request
      Attribute Description: Certificate Request
      Attribute Syntax: cert_request

    Input ID: i2
    Name: Requestor Information
    Class: submitterInfoInputImpl

      Attribute Name: requestor_name
      Attribute Description: Requestor Name
      Attribute Syntax: string

      Attribute Name: requestor_email
      Attribute Description: Requestor Email
      Attribute Syntax: string

      Attribute Name: requestor_phone
      Attribute Description: Requestor Phone
      Attribute Syntax: string


Adding the ``--output <filename>`` argument to the above command
downloads the certificate enrolment request template for our new
``caServerCertTest`` profile.  Using it to submit a CSR with a
subject common name (CN) *not* starting with ``test.`` results in
summary rejection as hoped, and submission succeeds when the CN does
satisfy our constraint.

In the next post we'll dive into some code to look at how inputs,
constraints and defaults are actually implemented, and perhaps
implement one or two of our own.

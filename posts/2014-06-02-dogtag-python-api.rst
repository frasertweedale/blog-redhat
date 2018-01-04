Introduction to the Dogtag Python API
=====================================

There is a Python binding to the Dogtag REST API under active
development by Abhishek Koneru.  I will be using this API to add
support for Dogtag profiles in FreeIPA.  This post serves as an
introduction to the API, with a particular focus on the
profile-related parts.

Because it's still in development, the API is subject to change.  I
think the overall structure of the API is fine so hopefully any
changes will be minor.  The API is well documented so if in doubt,
check the docstrings (calling ``help(<module|class|object>)`` is a
handy way to read the docs in the interactive Python interpreter).


PKIConnection
-------------

The ``pki.client.PKIConnection`` class connects to a Dogtag instance
and executes REST verbs on behalf of clients.  Internally, it uses
the excellent Requests_ library.

.. _Requests: http://docs.python-requests.org/en/latest/

.. code:: python

  import pki.client

  scheme = 'https'
  host = 'localhost'
  port = '8443'
  subsystem = 'ca'
  conn = pki.client.PKIConnection(scheme, host, port, subsystem)

For actions that require authentication, a client certificate is
required, in PEM format.  Client certificates are often distributed
in the PKCS #12 format.  In such case, the following command will
convert a PKCS #12 client certificate to an unencrypted PEM
certificate::

  $ openssl pkcs12 -nodes -in cl_cert.p12 -out cl_cert.pem

After telling the ``PKIConnection`` where to find the client
certificate, the connection object will be ready to use:

.. code:: python

  conn.set_authentication_cert("/path/to/cl_cert.pem")


ProfileClient
-------------

The ``pki.profile.ProfileClient`` class proxies the profiles-related
REST resources.

.. code:: python

  import pki.profile

  profile_client = pki.profile.ProfileClient(conn)
  profiles = profile_client.list_profiles()
  for profile in profiles:
    pass  # do stuff

``list_profiles()`` also takes optional ``start`` and ``size``
keyword arguments for pagination.  For inspecting an individual
profile, there is the ``get_profile`` method.  But first let's see
what happens when we ask for a profile that doesn't exist::

  >>> profile = profile_client.get_profile('nope')
  Traceback (most recent call last):
    File "<stdin>", line 1, in <module>
    File "pki/__init__.py", line 234, in handler
      raise pki_exception
    pki.ProfileNotFoundException: Profile ID nope not found

So there are nice, specific exception types.  There's a whole bunch
of domain-specific exceptions, but I won't list them here.  Moving
on, we can have a look at a profile that *does* exist::

  >>> profile = profile_client.get_profile('caServerCert')
  >>>
  >>> profile
  {'ProfileData': {'status': 'enabled', 'visible': True,
  'profile_id': u'caServerCert', 'name': u'Manual Server Certificate
  Enrollment', 'description': u'This certificate profile is for
  enrolling server certificates.'}}
  >>>
  >>> dir(profile)
  ['Input', 'Output', 'PolicySets', '__class__', '__delattr__',
  '__dict__', '__doc__', '__fo rmat__', '__getattribute__',
  '__hash__', '__init__', '__module__', '__new__', '__reduce__' ,
  '__reduce_ex__', '__repr__', '__setattr__', '__sizeof__',
  '__str__', '__subclasshook__', '__weakref__', 'authenticator_id',
  'authorization_acl', 'class_id', 'description', 'enabl ed',
  'enabled_by', 'from_json', 'inputs', 'link', 'name', 'outputs',
  'policy _sets', 'profile_id', 'renewal', 'visible', 'xml_output']

The relevant attributes can be gleaned from above.  At the moment,
there's not a whole lot you can do with a profile object, besides
look at it.  It contains some metadata about the profile and lists
of its inputs, outputs and policies (defaults and constraints).

There's not much else to the profiles aspect of the API at this
time.  You can list profiles, inspect profiles, and enable/disable
profiles, but you aren't yet able to create new profiles or perform
more advanced profile administration.  Future work will (hopefully)
add these capabilities.


CertClient
----------

Although ``pki.profile`` on its own doesn't currently offer a lot to
the API end-user, some other modules do leverage the provided
classes and methods in their own behaviours.  ``pki.cert`` is one
such module.

.. code:: python

  import pki.cert

  cert_client = pki.cert.CertClient(conn)

  # enrol a certificate
  inputs = {
    "cert_request_type": "pkcs10",
    "cert_request": "MIIBmDCC... (a PEM certificate request)",
    "requestor_name": "John A. Citizen",
    "requestor_email": "jcitizen@example.tld",
  }
  enroll_req = cert_client.create_enrollment_request("caServerCert", inputs)
  req_infos = cert_client.submit_enrollment_request(enroll_req)

The above instantiates a ``CertClient`` (reusing the connection
object from before), creates a certificate enrollment request for
the ``caServerCert`` profile (using the given inputs) and submits
the certificate enrollment request.  A certificate enrollment can
actually involve multiple certificates, so the ``req_infos``
variable above contains a ``CertRequestInfoCollection`` object.
Completing the enrollment involves iterating over this collection
and approving each certificate request.

.. code:: python

  certificates = []
  for req_info in req_infos:
    req_id = req_info.request_id
    cert_client.approve_request(req_id)
    cert_id = cert_client.get_request(req_id).cert_id
    certificates.append(cert_client.get_cert(cert_id))

Assuming nothing went wrong, ``certificates`` now contains a
``list`` of ``pki.cert.CertData`` objects, but took quite a few
operations to get from the enrollment request inputs to our actual
certificate(s).  Fortunately, the API provides a convenience method to take care of all these details:

.. code:: python

  profile_id = "caServerCert"
  certificates = cert_client.enroll_cert(profile_id, inputs)

``enroll_cert`` takes care of all the details and returns a list of
``CertData`` objects when it completes.  If this particular process
of certificate enrollment request generation, submission, approval
and certificate retrieval turns out to be a common use case, this
method will save a lot of typing, but it's important to know how it
works and what it does behind the scenes.

Let's now have a look at one of these ``CertData`` objects::

  >>> type(cert)
  <class 'pki.cert.CertData'>
  >>>
  >>> cert
  {'CertData': {'status': u'VALID', 'serial_number': u'0x17',
  'subject_dn': u'CN=TestServer,O=Red Hat Inc.,L=Raleigh,ST=NC,C=US'}}
  >>>
  >>> dir(cert)
  ['__class__', '__delattr__', '__dict__', '__doc__', '__format__',
  '__getattribute__', '__hash__', '__init__', '__module__',
  '__new__', '__reduce__', '__reduce_ex__', '__repr__',
  '__setattr__', '__sizeof__', '__str__', '__subclasshook__',
  '__weakref__', 'encoded', 'from_json', 'issuer_dn', 'link',
  'nonce', 'not_after', 'not_before', 'pkcs7_cert_chain',
  'pretty_repr', 'serial_number', 'status', 'subject_dn']
  >>>
  >>> cert.encoded
  u'-----BEGIN CERTIFICATE-----\nMIIDFjCCA... (a PEM-encoded certificate)'

It has all the things you'd expect a data type representing a
digital certificate to have.

As you might expect, enrolling new certificates is not the only way
to get at a ``CertData`` object.  The ``CertClient`` API supports
listing and searching certificates, revocation and more.  It also
supports the whole gamut of CA agent operations with respect to
pending certificate requests.  In addition to approving requests,
requests can be reviewed, rejected, assigned to another agent, and
so on.


Conclusion
----------

There are many details and features of the Dogtag Python API that
were not covered in this post, but the most important details have
been covered, and I hope I have conveyed a comprehension of the
high-level organisation of the API and the common idioms.

As mentioned at the beginning of this post, the API is not yet
released and is subject to change, but feel free to `have a look at
the code`_ or begin experimenting with it.  The Dogtag developers
welcome feedback and `pki-devel mailing list`_ is the place to
provide it.

.. _have a look at the code: https://git.fedorahosted.org/cgit/pki.git
.. _pki-devel mailing list: http://www.redhat.com/mailman/listinfo/pki-devel

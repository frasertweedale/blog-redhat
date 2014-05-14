..
  Copyright 2014 Red Hat, Inc.

  This work is licensed under a
  Creative Commons Attribution 4.0 International License.

  You should have received a copy of the license along with this
  work. If not, see <http://creativecommons.org/licenses/by/4.0/>.


Dogtag certificate profiles - certificate requests
==================================================

The *certificate enrolment profiles* feature of Dogtag PKI can be
used to specify default values and constraints for X.509 certificate
fields.  This post explores Dogtag certificate profiles and their
relationship with the PKCS #10 certificate signing request (CSR)
format with a focus on signing request submission.  Future posts in
this series will focus on the Certificate Authority (CA) side of the
profiles feature, and on modifying and defining profiles for
specialised use cases.

Let us begin by generating a CSR.  This occurs in isolation from
Dogtag profiles or certificate enrolment, and is done using
``certutil`` (CSRs can also be generated with ``openssl req``).

::

  certutil -R -d .pki/nssdb -o no-CN.req -a -s 'C=AU, ST=Queensland, L=Brisbane, O=Red Hat'

The ``-o no-CN.req`` instructs ``certutil`` to output the CSR to a file,
while ``-a`` specifies ASCII output.  Note that the subject (given
by ``-s``) does not contain a common name (CN) component.

CSRs are submitted to Dogtag in the context of some certificate
profile.  Available profiles can be listed via ``pki
cert-request-profile-find ""``, and the Certificate Enrolment
Request template for a profile can be retrieved via ``pki
cert-request-profile-show <profile ID> --output <filename>``.
Let's have a look at the ``caServerCert`` profile template:

.. code:: xml

  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
  <CertEnrollmentRequest>
      <ProfileID>caServerCert</ProfileID>
      <Renewal>false</Renewal>
      <SerialNumber></SerialNumber>
      <RemoteHost></RemoteHost>
      <RemoteAddress></RemoteAddress>
      <Input id="i1">
          <ClassID>certReqInputImpl</ClassID>
          <Name>Certificate Request Input</Name>
          <Attribute name="cert_request_type">
              <Value></Value>
              <Descriptor>
                  <Syntax>cert_request_type</Syntax>
                  <Description>Certificate Request Type</Description>
              </Descriptor>
          </Attribute>
          <Attribute name="cert_request">
              <Value></Value>
              <Descriptor>
                  <Syntax>cert_request</Syntax>
                  <Description>Certificate Request</Description>
              </Descriptor>
          </Attribute>
      </Input>
      <Input id="i2">
          <ClassID>submitterInfoInputImpl</ClassID>
          <Name>Requestor Information</Name>
          <Attribute name="requestor_name">
              <Value></Value>
              <Descriptor>
                  <Syntax>string</Syntax>
                  <Description>Requestor Name</Description>
              </Descriptor>
          </Attribute>
          <Attribute name="requestor_email">
              <Value></Value>
              <Descriptor>
                  <Syntax>string</Syntax>
                  <Description>Requestor Email</Description>
              </Descriptor>
          </Attribute>
          <Attribute name="requestor_phone">
              <Value></Value>
              <Descriptor>
                  <Syntax>string</Syntax>
                  <Description>Requestor Phone</Description>
              </Descriptor>
          </Attribute>
      </Input>
  </CertEnrollmentRequest>

The template is XML, containing *fields* with *attributes* whose
values are not yet specified.  Filling out these attributes with
the content of the CSR generated earlier along with some ancillary
information, we end up with the following:

.. code:: xml

  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
  <CertEnrollmentRequest>
      <ProfileID>caServerCert</ProfileID>
      <Renewal>false</Renewal>
      <SerialNumber></SerialNumber>
      <RemoteHost></RemoteHost>
      <RemoteAddress></RemoteAddress>
      <Input id="i1">
          <ClassID>certReqInputImpl</ClassID>
          <Name>Certificate Request Input</Name>
          <Attribute name="cert_request_type">
              <Value>pkcs10</Value>
              <Descriptor>
                  <Syntax>cert_request_type</Syntax>
                  <Description>Certificate Request Type</Description>
              </Descriptor>
          </Attribute>
          <Attribute name="cert_request">
                  <Value>
  MIIBhjCB8AIBADBHMRAwDgYDVQQKEwdSZWQgSGF0MREwDwYDVQQHEwhCcmlzYmFu
  ZTETMBEGA1UECBMKUXVlZW5zbGFuZDELMAkGA1UEBhMCQVUwgZ8wDQYJKoZIhvcN
  AQEBBQADgY0AMIGJAoGBAJvkY6CyMdY0u7hwFzfG9ZdajT+69bbRh1vqFIArGhhv
  vL09Em2MrlAhQEKF6PuAcdED7U7ryoBByeXDRfivFwQS5W5msVBkA5gZ1i9LyH82
  xULvkdnNFu6He8QnxLr8+bl/r9tdlktP/3k79hHmWRpqBtOqVKtBCwMqEdPltF7H
  AgMBAAGgADANBgkqhkiG9w0BAQUFAAOBgQB5Slu71g30osgQd25puSrUxNf6+eQk
  KEpWfrsrpRh7nOkAo3QmBmR4L7i5tUChnIv6UGi8qTeEWNHnMBcwgoe56tg5vqpK
  mmaz3W1w8hxima/cSqzqWgw4U/JMDU1nBSYz2WJTyEUUvdDD1lSsWzrqFi5f/vC3
  VjjWvio/DSvrgw==
                  </Value>
              <Descriptor>
                  <Syntax>cert_request</Syntax>
                  <Description>Certificate Request</Description>
              </Descriptor>
          </Attribute>
      </Input>
      <Input id="i2">
          <ClassID>submitterInfoInputImpl</ClassID>
          <Name>Requestor Information</Name>
          <Attribute name="requestor_name">
              <Value>ftweedal</Value>
              <Descriptor>
                  <Syntax>string</Syntax>
                  <Description>Requestor Name</Description>
              </Descriptor>
          </Attribute>
          <Attribute name="requestor_email">
              <Value>ftweedal@redhat.com</Value>
              <Descriptor>
                  <Syntax>string</Syntax>
                  <Description>Requestor Email</Description>
              </Descriptor>
          </Attribute>
          <Attribute name="requestor_phone">
              <Value></Value>
              <Descriptor>
                  <Syntax>string</Syntax>
                  <Description>Requestor Phone</Description>
              </Descriptor>
          </Attribute>
      </Input>
  </CertEnrollmentRequest>

With these fields filled out, the enrolment request can now be
submitted to Dogtag::

  $ pki cert-request-submit no-CN-req.xml
  -----------------------------
  Submitted certificate request
  -----------------------------
    Request ID: 12
    Type: enrollment
    Request Status: rejected
    Operation Result: success

Boo!  The enrolment request was rejected.  Why?  Certificate
profiles can specify constraints on user-supplied values in a
certificate request.  In this case, it was the lack of a ``CN``
field in the subject, but profiles can also summarily reject an
enrolment request based on other aspects of the embedded CSR,
including key type and size.

Let's now bring some extensions into the mix by generating a new
signing request - this time with a valid subject, and with the *Key
Usage* extension configured to indicate a certificate signing
certificate (i.e., an intermediate CA).  It obviously makes no
sense to have this extensions on a server certificate, but let's
submit it with the ``caServerCert`` profile again and see what
happens.

::

  $ certutil -R -d .pki/nssdb -o usage-ca.req -a --keyUsage certSigning -s 'CN=c2.vm-096.idm.lab.bos.redhat.com'
  ...
  $ openssl req -text < usage-ca.req
  Certificate Request:
      Data:
          Version: 0 (0x0)
          Subject: CN=c2.vm-096.idm.lab.bos.redhat.com
          Subject Public Key Info:
              Public Key Algorithm: rsaEncryption
                  Public-Key: (1024 bit)
                  Modulus:
                      00:bc:6e:11:11:6f:e5:3c:34:03:8a:5f:92:41:44:
                      ...
                      9b:bf:86:8e:df:96:9e:e6:ef
                  Exponent: 65537 (0x10001)
          Attributes:
          Requested Extensions:
              X509v3 Key Usage:
                  Certificate Sign
      Signature Algorithm: sha1WithRSAEncryption
           b0:4a:19:2c:c1:36:07:db:6a:bb:a9:36:0b:a4:53:c9:39:6d:
           ...

We can see that Key Usage extension is present in the request, and
contains (only) the *Certificate Sign* declaration.  We fill out and
submit the enrolment request with this CSR::

  $ pki cert-request-submit usage-ca-req.xml
  -----------------------------
  Submitted certificate request
  -----------------------------
    Request ID: 14
    Type: enrollment
    Request Status: pending
    Operation Result: success

Perhaps surprisingly, this succeeds and the enrolment request is now
*pending*, waiting for approval (or rejection) by a CA agent. It
seems that, at least for the ``caServerCert`` profile, the value of
the Key Usage extension in a CSR is ignored.  The agent interface
does allow adjustment of the Key Usage extension, however, and
enforces sensible constraints, so no request submitted in the
``caServerCert`` profile will ever result in a certificate that
could be used as in intermediate CA.

We have seen that Dogtag ignores the Key Usage extension information
present in a CSR, but in fact, Dogtag ignores *all* information in
the CSR except for what it specifically extracts.  Therefore,
requesting a particular key signing algorithm does not necessarily
result in a certificate signed using that algorithm, and requesting
some extension unknown in the selected profile (e.g., the
*Certificate Policies* extension, which can be included in a CSR via
the ``--extCP`` argument to ``certmonger``) will **certainly not**
be present in the certificate.

As a newcomer to the Dogtag PKI I find this behaviour somewhat
limiting and would like to investigate whether the profiles system
supports profiles that afford more control over the presense of
extensions or the signing process, or what it would take to get this
support.

The next post in this series will investigate how profiles are
defined and the kinds of inputs and constraints they support.

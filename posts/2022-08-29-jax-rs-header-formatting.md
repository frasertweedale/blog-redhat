---
tags: programming, java
---

# Controlling header formatting in JAX-RS applications

I'm been implementing an [*Enrollment over Secure Transport
(EST)*][RFC 7030] service in Dogtag PKI.  During testing, I found
that a notable client implementation parses the response
`Content-Type` header in the following way:

```c
if (!strncmp(
    multipart_get_data_content_type(parser),
    "application/pkcs7-mime; smime-type=certs-only",
    45)
  ) {
    ...
```

The Dogtag EST service is a [*Jakarta RESTful Web Services
(JAX-RS)*][JAX-RS] application.  It produces a `Content-Type` header
value different from what the client expects (note the lack of
whitespace):

```
application/pkcs7-mime;smime-type=certs-only
```

[JAX-RS]: https://projects.eclipse.org/projects/ee4j.rest
[RFC 7030]: https://www.rfc-editor.org/rfc/rfc7030

As a consequence, the EST client fails to process the response.
This is certainly a defect in the EST client implementation.  But
EST is used by many embedded or hard to update network devices.  Or
updates might not be available (now, *ever?*)

So, I needed to find a way to override the header default header
formatting.  This blog post describes my solution.


## Specifying the `Content-Type` header

The JAX-RS `@Produces` annotation specifies the `Content-Type`
header value for a particular resource:

```java
@POST
@Path("simpleenroll")
@Consumes("application/pkcs10")
@Produces("application/pkcs7-mime; smime-type=certs-only")
public Response simpleenroll(byte[] data) {
    ...
```

Note that the string value is not used *verbatim*.  Instead, it is
parsed into a [`MediaType`][MediaType] value and stored as such in
the response headers (a `MultivaluedMap<String, Object>`).

When serialising the `Response`, header values are stringified via
types that implement the
[`RuntimeDelegate.HeaderDelegate<T>`][HeaderDelegate] interface,
where `T` is the real type of the header value `Object`.  To
serialise a `MediaType` header value, the JAX-RS machinery uses a
instance of a a class that implements
`RuntimeDelegate.HeaderDelegate<MediaType>`.

`HeaderDelegate` *implementations* are not part of the JAX-RS API.
They are provided by the JAX-RS implementation.  In Dogtag PKI,
that's [RESTEasy][].  The class in question is:

[MediaType]: https://docs.oracle.com/javaee/7/api/javax/ws/rs/core/MediaType.html
[HeaderDelegate]: https://docs.oracle.com/javaee/7/api/javax/ws/rs/ext/RuntimeDelegate.HeaderDelegate.html
[RESTEasy]: https://resteasy.dev/

```java
public class MediaTypeHeaderDelegate
  implements RuntimeDelegate.HeaderDelegate<MediaType> {
```

The `toString(MediaType type)` method provided by this class prints
the value without a space character between the subtype and the
parameters.  For the example resource above, it produces the string:

```
application/pkcs7-mime;smime-type=certs-only
```

This is a legal production in the HTTP grammar, according to [RFC
7230][] and [RFC 7231][]:

```
media-type = type "/" subtype *( OWS ";" OWS parameter )
OWS = *( SP / HTAB )
```

[RFC 7230]: https://www.rfc-editor.org/rfc/rfc7230#section-3.2.3
[RFC 7231]: https://www.rfc-editor.org/rfc/rfc7231#section-3.1.1.1

However, we already saw that at least one EST client is unable to
process this value, because it expects a space character before the
parameters:

```
application/pkcs7-mime; smime-type=certs-only
```

This is also a legal production.  But the client is using `strncmp`
to look for this exact string, instead of properly parsing the
value.  If we can't fix the client behaviour, we have to find a
workaround on the server to produce the exact string the client
expects.

## Idea 1: custom `HeaderDelegate`

My first idea was to override the `HeaderDelegate<MediaType>` with
our own implementation.  I couldn't find a general way to do that
via the JAX-RS API.  It does seem that you can do it using RESTEasy
classes directly:

1. Implement the custom `HeaderDelegate<MediaType>`.  To avoid
   unnecessary work you could extend RESTEasy's
   `MediaTypeHeaderDelegate` and override just the
   `toString(MediaType)` method.

2. Obtain `ResteasyProviderFactory.getInstance()`.  Invoke
   `.addHeaderDelegate(MediaType.class, customInst)` to replace the
   `HeaderDelegate<MediaType>`.

This approach has several disadvantages:

- Directly coupled to the RESTEasy implementation.  May break if
  RESTEasy implementation details change and will not work with
  other JAX-RS implementations.

- Need to implement a custom `HeaderDelegate<MediaType>` with the
  "correct" serialisation behaviour.

- **The "correct" serialisation behaviour might break *other* clients
  with different bugs/quirks.**

For these reasons I rejected the first idea and sought an approach
that avoids these disadvantages.

## Idea 2: response filter

My next idea was to use a *response filter* to reformat the
`Content-Type` response header.  The Servlet API defines the
[`ContainerResponseFilter`][ContainerResponseFilter] interface:

```java
public interface ContainerResponseFilter {
  void filter(
      ContainerRequestContext requestContext,
      ContainerResponseContext responseContext)
    throws IOException
}
```

[ContainerResponseFilter]: https://docs.oracle.com/javaee/7/api/javax/ws/rs/container/ContainerResponseFilter.html

The application applies each registered filter to each response,
before serialising and sending the response.  At the time response
filters are applied, the `Content-Type` header value is a
`MediaType`.  It has not yet been converted to a `String`.

A response filter can add, remove, or replace response headers.
Recall that headers are stored in a `MultivaluedMap<String,
Object>`.  This means that we can replace a `MediaType` value (whose
serialisation is determined by the `HeaderDelegate`) with a `String`
value (which will be written *as is*).

The `.equals` equality test for `MediaType` properly compares the
properties of the instance without regard to string representation.
As it should.  This enables a succinct implementation where we:

1. Decalre *verbatim* `String` header values we want to see in the
   response.

2. Parse those strings into `MediaType` values.

3. Match the `Content-Type` value in the response against parsed
   values.

4. Replace matched header values with the corresponding *verbatim*
   `String`.

The implementation is straightforward:

```java
@Provider
public class ReformatContentTypeResponseFilter
    implements ContainerResponseFilter {

  private static String[] verbatim = {
    "application/pkcs7-mime; smime-type=certs-only"
  };

  private static HashMap<MediaType, String> substitutions =
    new HashMap<>();

  static {
    for (String s : verbatim)
      substitutions.put(MediaType.valueOf(s), s);
  }

  @Override
  public void filter(
      ContainerRequestContext requestContext,
      ContainerResponseContext responseContext) {
    MultivaluedMap<String, Object> headers =
      responseContext.getHeaders()
    Object v = headers.getFirst(HttpHeaders.CONTENT_TYPE);
    if (v != null && v instanceof MediaType
        && substitutions.containsKey(v)) {
      headers.putSingle(
        HttpHeaders.CONTENT_TYPE, substitutions.get(v));
    }
  }

}
```

There is currently only one header value whose formatting I need to
precisely control.  If we discover more, we only need to add the
desired string serialisation to the `verbatim` array.

We must consider the possible scenario of different clients with
different quirks.  In that case, we could maintain separate
substitutions maps for each known problematic client.  We would use
the `User-Agent` header, or other request characteristics, to
identify the client and select the corresponding substitution map
(if any).  Hopefully this situation does not arise.  But if it does,
the increase in complexity of the solution is tolerable.

This solution works well and avoids the disadvantages of my first
idea:

- Only uses official Servlet and JAX-RS classes and interfaces.
  This solution will work across all JAX-RS implementations.

- Does not (re)implement `MediaType` serialsation.  You just declare
  the exact string values you want to see in responses.

- With a moderate increase in complexity, can handle different
  clients with incompatible quriks.

## Conclusion

It's unfortunate that this workaround was even necessary.  But given
that it was, I'm happy with the solution.  It is simple and portable
across Servlet and JAX-RS implementations.

The same approach could be used for controlling formatting of any
header value types, not just `Content-Type` / `MediaType`.  I hope
that sharing this solution will help people who encounter similar
problems.  At the very least, I hope that because of this post you
learned something about Servlet and JAX-RS response header
processing.

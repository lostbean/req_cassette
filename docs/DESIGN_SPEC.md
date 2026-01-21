# **ReqCassette: A Full Design Specification for VCR Testing with the Req Library**

> **Note:** This is a historical design document from the initial development of
> ReqCassette (v0.1-v0.2). While the architectural principles remain valid, some
> implementation details have evolved. For current API documentation, see:
>
> - [README.md](../README.md) - Current API and usage examples
> - [Templating Guide](guides/templating.md) - Template feature documentation
> - [Migration Guides](.) - Version upgrade instructions
>
> Key changes since this document was written:
>
> - The `use_cassette` macro was replaced by `with_cassette/3` function in v0.2
> - Sequential matching available via `sequential: true` option (v0.5)
> - Templates automatically enable sequential matching (v0.5)
> - Cross-process support via `start_shared_session/end_shared_session` (v0.5)
> - Templating system for parameterized cassettes (v0.3+)

## **1.0 Executive Summary & Architectural Vision**

This document presents a comprehensive design specification for ReqCassette, a
new testing support library for the Elixir programming language. The library is
designed to provide robust, VCR-like record-and-replay functionality exclusively
for the Req HTTP client. Its primary objective is to empower developers to
create fast, deterministic, and reliable test suites for applications that
depend on external HTTP services. By eliminating network latency and
unpredictability from the testing loop, ReqCassette will significantly improve
developer productivity and the stability of continuous integration (CI)
pipelines.

### **1.1 Project Mission and Purpose**

The mission of ReqCassette is to provide a seamless and intuitive testing
experience for developers using the Req library. It achieves this by
implementing the well-established VCR pattern, which has proven invaluable in
ecosystems like Ruby.1 The core operational principle is straightforward yet
powerful: during the initial execution of a test, ReqCassette intercepts any
outgoing HTTP requests made via Req, performs the actual network call, and
records the complete request-response interaction into a human-readable file
known as a "cassette".2 On all subsequent test runs, the library intercepts the
same request, but instead of accessing the network, it finds the matching
interaction in the cassette and replays the stored response. This mechanism
provides several critical benefits:

- **Speed:** Tests execute almost instantaneously by reading from the local
  filesystem instead of waiting for network round-trips.3
- **Determinism:** Test outcomes are no longer subject to the availability,
  latency, or fluctuating data of external services. The response is guaranteed
  to be the same every time.4
- **Offline Capability:** Development and testing can proceed without an active
  internet connection once cassettes have been recorded.5
- **Cost and Rate-Limit Reduction:** It eliminates the need to make repeated
  calls to paid or rate-limited APIs during test execution.3

### **1.2 The Modern Architectural Foundation: Req.Test and Plug**

The foundational design of ReqCassette represents a deliberate and strategic
departure from the implementation patterns of earlier Elixir VCR libraries like
ExVCR. Instead of relying on the powerful but intrusive Erlang mocking library
:meck to globally patch underlying HTTP client modules such as hackney or
ibrowse 2, ReqCassette will be built entirely upon Req's native, first-class
testing infrastructure. The Req library was explicitly designed with testability
as a core tenet. It exposes a :plug option within its request functions and the
Req.Test module to facilitate this.8 This powerful feature allows the entire
networking layer of a Req request to be swapped out at runtime with any module
that conforms to the Plug specification.11 This is the central architectural
pillar of ReqCassette. The library will provide a sophisticated Plug module that
acts as the interception and dispatching engine. When a Req request is initiated
within a test, it will be routed to this Plug. The Plug will then intelligently
decide whether to proxy the request to a real network connection for recording
or to serve a pre-recorded response directly from a cassette file. This approach
aligns perfectly with modern Elixir testing practices, as detailed in guides for
testing Req applications.13

### **1.3 Core Differentiators and Strategic Advantages**

This modern architectural choice provides ReqCassette with significant
advantages over existing solutions, positioning it as the definitive VCR tool
for the Req ecosystem.

- **Concurrency Safety:** The most significant benefit of the Plug-based
  architecture is its inherent compatibility with ExUnit's async: true setting.
  The :meck library, used by ExVCR, operates by modifying module code in a
  global manner. This global state mutation is fundamentally at odds with the
  BEAM's process-isolated concurrency model and often forces developers to
  disable asynchronous testing (async: false) to prevent race conditions and
  test pollution.4 In contrast, Req's :plug option is configured per-request and
  operates within the context of the calling test process. This allows
  ReqCassette to be fully process-isolated, enabling test suites to run in
  parallel and at maximum speed.
- **Simplicity and Reduced Coupling:** ExVCR must maintain specific "adapters"
  for each HTTP client it supports (hackney, finch, ibrowse, etc.), making it
  tightly coupled to their internal implementations.2 ReqCassette avoids this
  complexity entirely. By interfacing solely with the stable and public APIs of
  Req and Plug, it does not need to be aware of the underlying HTTP adapter Req
  is using. This makes the library more focused, significantly easier to
  maintain, and resilient to upstream changes in low-level dependencies.
- **First-Class Req Integration:** As a library designed exclusively for Req,
  ReqCassette can provide deeper and more reliable integration. It will be
  meticulously tested to ensure that all of Req's advanced features—such as
  request and response streaming, automatic redirect following, multipart form
  uploads, and built-in authentication helpers—are correctly captured and
  replayed with high fidelity.8 This specialized focus guarantees that the
  recorded interactions are a true representation of Req's behavior.

The decision to build upon Req.Test and Plug is not merely a technical
preference but a strategic alignment with the evolution of testing philosophy in
the Elixir community. Early tools adopted patterns from the Erlang ecosystem,
like :meck, which were powerful but did not fully embrace the process-centric
model that makes Elixir excel at concurrency. Modern libraries such as Mox,
Bypass, and Req itself champion a contract-based, dependency-injection approach
that is process-isolated and aligns perfectly with OTP principles. By adopting
this modern paradigm, ReqCassette learns from the limitations of its
predecessors and offers a more robust, performant, and idiomatic solution for
today's Elixir developers.

## **2.0 The ReqCassette Developer Experience: Public API Specification**

The public API of ReqCassette is designed with two primary goals: intuitiveness
and power. The developer experience should be as frictionless as possible,
minimizing boilerplate and allowing users to focus on their test logic rather
than the tooling. The design draws inspiration from the successful patterns
established by ExVCR and the original Ruby VCR.1

### **2.1 Core Usage: The use\_cassette/2 Macro**

The primary interface for using ReqCassette within a test suite will be the
use\_cassette/2 macro. This macro wraps a block of code, activating the
recording and replaying mechanism for all Req calls made within its scope.
Syntax: The macro will be imported into the test module via use ReqCassette. Its
signature is use\_cassette(cassette\_name, options \\\\), where cassette\_name
is a string or atom that determines the filename of the cassette. **Example
Usage:**

Elixir

defmodule MyApp.GithubClientTest do use ExUnit.Case, async: true \# Imports the
use\_cassette/2 macro and other helpers. use ReqCassette

test "fetches user data from the GitHub API" do \# This block will either record
to or replay from \# "test/fixtures/cassettes/github\_user\_wojtekmach.json".
use\_cassette "github\_user\_wojtekmach" do {:ok, response} \=
Req.get("https://api.github.com/users/wojtekmach")

      assert response.status \== 200
      assert is\_map(response.body)
      assert response.body\["login"\] \== "wojtekmach"
    end

end end

### **2.2 Options for use\_cassette/2**

The use\_cassette/2 macro will accept a keyword list of options to provide
fine-grained control over its behavior. This flexibility is essential for
handling various testing scenarios, from local development to CI environments.

- :record (atom): This option controls the recording mode of the cassette.
  - :once (default): This is the standard mode. If the cassette file does not
    exist, it will be recorded. If it exists, its contents will be replayed. If
    a request is made that does not have a matching interaction in an existing
    cassette, an error will be raised.
  - :new\_episodes: This mode is useful for incrementally adding new
    interactions to an existing cassette. It will replay any matching requests
    it finds but will perform and record any new, unrecorded requests, appending
    them to the cassette file.
  - :all: This mode forces re-recording. It ignores any existing cassette file
    and performs all HTTP requests live, overwriting the cassette with the new
    interactions.
  - :none: This mode disables recording entirely. It will only replay from an
    existing cassette. If a request is made that does not have a matching
    interaction, an error will be raised. This is the recommended mode for CI
    environments to ensure no unintended network calls are made.5
- :match\_requests\_on (list of atoms): This option defines the criteria used to
  determine if an incoming request matches a recorded interaction. The default
  will be \[:method, :uri\]. A detailed specification of available matchers is
  provided in Section 5.1.
- :update\_content\_for (list of atoms): When re-recording a cassette (e.g.,
  with :record, :all), this option allows specifying which parts of a recorded
  interaction should be updated while preserving others. For instance, one might
  want to update the response body and headers but keep the original request
  body for comparison.
- :exclusive (boolean): When set to true, this option prevents other
  use\_cassette blocks from being nested inside the current one. This can help
  avoid complex and potentially confusing test setups. Defaults to false.

### **2.3 Setup and Configuration (ReqCassette.Config)**

Global configuration for ReqCassette will be managed through a dedicated
ReqCassette.Config module. This centralized approach is cleaner than ExVCR's
pattern of calling configuration functions within individual setup blocks 2, as
it allows for a single point of configuration in the test/test\_helper.exs file.
**test/test\_helper.exs Setup Example:**

Elixir

ExUnit.start()

ReqCassette.Config.setup( \# Sets the root directory for all cassette files.
cassette\_library\_dir: "test/fixtures/cassettes",

\# Globally redact API keys from all recorded interactions.
filter\_sensitive\_data: {"ApiKey", ""},

\# Globally remove a noisy header from all recordings.
filter\_response\_headers: \["x-request-id"\] )

**Key Configuration Functions:**

- setup(options): A convenience function to set multiple configuration values at
  once.
- cassette\_library\_dir(path): Sets the root directory where cassette files are
  stored.
- filter\_sensitive\_data(pattern, placeholder): Defines a global rule for
  redacting sensitive information. The pattern can be a string or a regular
  expression, and placeholder is the string used for replacement. This is
  critical for keeping secrets out of source control.2
- filter\_request\_headers(header\_name) and
  filter\_response\_headers(header\_name): Defines global rules for removing
  specific headers from the recorded request or response.
- before\_record(fun) and before\_playback(fun): Provides global callback hooks.
  These functions receive the full interaction data (as an Elixir map) and can
  programmatically modify it before it is written to disk or replayed. This
  enables complex logic, such as modifying timestamps or signing requests.

### **2.4 Mix Tasks**

To improve the developer workflow and provide command-line utilities for
managing cassettes, ReqCassette will ship with a set of Mix tasks, similar to
those offered by ExVCR.2

- mix cassette.eject: Deletes all cassette files from the configured
  cassette\_library\_dir. This is a convenient way to force all tests to
  re-record their interactions against the live services.
- mix cassette.check: Iterates through all cassette files, attempting to parse
  them. This task will fail if any cassette is corrupted or not valid JSON,
  helping to catch manual editing errors.
- mix cassette.show \<name\>: Finds a cassette by its name and pretty-prints its
  contents to the console. This is useful for quickly inspecting the data
  recorded for a specific test without opening the file.

## **3.0 Internal Architecture: The ReqCassette Plug**

The core of ReqCassette's functionality is encapsulated within a single,
powerful component: the ReqCassette.Plug. This module is the engine that
intercepts, replays, and records all HTTP interactions. Its design leverages the
stability and elegance of the Plug specification to provide a robust and
maintainable implementation.

### **3.1 The Role of the ReqCassette.Plug**

The ReqCassette.Plug module will implement the standard Plug behaviour, which
requires two functions: init/1 and call/2.11 It is not a web server plug in the
traditional sense; rather, it is a plug designed to be used with Req's testing
facilities. The use\_cassette macro is the mechanism that activates this plug.
When a test enters a use\_cassette block, the macro performs two key actions:

1. It stores the cassette's context (its name, record mode, matching options,
   etc.) in the test process's process dictionary. The process dictionary is a
   storage mechanism local to a single Elixir process, making it a safe and
   standard way to pass context in async: true tests without causing side
   effects in other, concurrent tests.
2. It ensures that all Req calls made within the block are configured to use
   ReqCassette.Plug. This is achieved by dynamically injecting the :plug option
   into the Req request struct.

A conceptual representation of how a Req call is transformed within the macro:

Elixir

\# User writes this: Req.get("https://example.com")

\# The use\_cassette macro effectively transforms it into this: cassette\_info
\= \#... context from process dictionary req \= Req.new(plug: {ReqCassette.Plug,
cassette\_info}) Req.get(req, "https://example.com")

This is the same mechanism recommended by the Req library for general test
stubbing, ensuring ReqCassette is using the library in an officially supported
manner.10

### **3.2 The call/2 Logic Flow**

The call/2 function is the heart of the library, where every intercepted request
is processed. It receives a %Plug.Conn{} struct representing the outgoing Req
request and is responsible for returning a modified %Plug.Conn{} that represents
the final response. The logic within this function follows a clear,
decision-driven path. Step 1: Context Retrieval The function first reads the
cassette context (name, options) from the process dictionary, which was placed
there by the use\_cassette macro. If no context is found, it indicates a
misconfiguration, and the plug will raise an error. Step 2: Cassette Loading The
plug loads the specified cassette file from the filesystem. If the file exists,
its JSON content is parsed into an in-memory list of Elixir maps, where each map
represents a single recorded interaction. If the file does not exist, the
in-memory list is initialized as empty. Step 3: Request Normalization The
incoming %Plug.Conn{} struct is transformed into a standardized map structure.
This "normalized request" contains the essential elements needed for matching:
method, URI, headers, and body. This step ensures that the live request can be
consistently compared against the stored interactions. Step 4: Interaction
Matching The plug iterates through the list of recorded interactions from the
cassette. For each recorded interaction, it applies the matching logic
configured by the :match\_requests\_on option (e.g., comparing method, URI, and
body). Step 5: Replay or Record Decision The outcome of the matching step
determines the next course of action.

- **If a Match is Found (Replay Path):**
  1. The corresponding recorded response is retrieved from the matched
     interaction map.
  2. The before\_playback callbacks and any dynamic templating are applied to
     the response data.
  3. A new %Plug.Conn{} is constructed using functions from the Plug.Conn
     module. The status code, headers, and body of this new connection are set
     to match the recorded response.10
  4. This fully formed response connection is returned. Req then receives this
     connection and translates it back into a standard Req.Response{} struct for
     the test to assert against.
- **If No Match is Found (Record Path):**
  1. The plug first checks the :record mode. If the mode is :none, or if it is
     :once and the cassette file already exists, an error is raised to inform
     the user of an unexpected request.
  2. If recording is permitted, the plug must perform a live network call. To do
     this, it constructs a _new_ Req.Request struct based on the original
     request. Critically, this new request struct is created _without_ the :plug
     option, ensuring that it will use Req's default network adapter (e.g.,
     Finch) and not call back into ReqCassette.Plug, which would create an
     infinite loop.
  3. The live request is executed: {:ok, response} \=
     Req.request(real\_request).
  4. The original normalized request and the newly received live response are
     packaged into a new interaction map, conforming to the cassette's schema.
  5. All configured data filters (for sensitive data, headers, etc.) and the
     before\_record callback are applied to this new interaction map.
  6. The new interaction is appended to the in-memory list of interactions for
     the current cassette.
  7. The entire updated list of interactions is serialized to JSON and written
     back to the cassette file on disk, overwriting the previous content.
  8. Finally, a %Plug.Conn{} is constructed from the live response and returned
     to the original Req call, ensuring the test proceeds with the real data on
     its first run.

This architecture provides a clean separation of concerns. The Req.Test and Plug
combination serves as a perfect abstraction layer, decoupling ReqCassette from
the volatile implementation details of the underlying HTTP clients. ExVCR
requires specific adapters because it directly patches modules like hackney and
ibrowse.2 This creates a significant maintenance burden, as any change in those
libraries could break ExVCR. ReqCassette, by contrast, only needs to understand
the stable %Plug.Conn{} struct. When it needs to make a real request, it doesn't
invoke Finch or hackney directly; it delegates this task back to Req itself.
This design is therefore far more robust, maintainable, and future-proof. Should
Req change its default adapter in a future version, ReqCassette will continue to
function without modification.

## **4.0 The Cassette Persistence Layer**

The persistence layer is a critical component of ReqCassette, as the cassette
files themselves are a primary point of interaction for the developer. The
format must be human-readable, easy to manage, and robust.

### **4.1 Cassette File Format Specification (JSON)**

The default serialization format for cassettes will be JSON. This choice aligns
with the precedent set by ExVCR 2 and takes advantage of the highly optimized
and ubiquitous Jason library within the Elixir ecosystem.3 Cassette files will
use the .json extension. The top-level structure of a cassette file will be a
JSON array, where each element is an "interaction" object representing a single
request/response cycle. Interaction Schema: Each interaction object will contain
the request, the response, and metadata about the recording.

JSON

} \]

**Schema Rationale:**

- **Human Readability:** This structure is easy for developers to read and
  understand. This is crucial for debugging tests and for manually creating or
  editing cassettes to simulate specific edge cases, a feature supported by
  ExVCR under the name "custom cassettes".2
- **Simplicity:** The schema is flat and straightforward, making it simple to
  parse and generate.
- **Rich Metadata:** Including recorded\_at provides context for when the data
  was captured, which can be useful for identifying stale cassettes. The
  match\_attributes field explicitly documents which parts of the request were
  used for matching during the recording, aiding in debugging matching failures.
- **Body Handling:** The body field for both request and response will be stored
  as a string. This allows for faithful representation of any content type
  (JSON, XML, plain text, etc.). The content-type header will provide the
  necessary context for interpretation.

### **4.2 File System Management**

The library will manage the creation and updating of cassette files in a
predictable and safe manner.

- **Directory Structure:** All cassettes will be stored in the directory
  specified by the ReqCassette.Config.cassette\_library\_dir/1 configuration
  setting. It is standard practice to place this directory at
  test/fixtures/cassettes and commit the cassettes to version control.
- **File Naming:** The cassette\_name string provided to the use\_cassette macro
  will be sanitized to create a valid filename. For example, a name like "GitHub
  API: get user profile" would be converted to
  github\_api\_get\_user\_profile.json.
- **Atomic Writes:** To prevent data corruption, especially if a test run is
  aborted mid-write, the library will employ an atomic file writing strategy. It
  will first write the new content to a temporary file and then, upon successful
  completion, rename the temporary file to the final cassette filename. This
  ensures that the original cassette remains intact until the new version is
  fully written.

### **4.3 Pluggable Serializers (Future Enhancement)**

While JSON is an excellent default, the internal architecture will be designed
to accommodate other serialization formats in the future, a feature present in
the mature Ruby VCR library.1 The core logic of the ReqCassette.Plug will
operate on a standard Elixir map representation of the cassette's interactions.
The persistence layer will be an abstraction responsible for encoding this map
structure to a binary for writing to disk and decoding a binary from disk back
into the map structure. This will be formalized through a ReqCassette.Serializer
behaviour. Users could then implement this behaviour for other formats (e.g.,
YAML, or even Elixir's native external term format via
:erlang.term\_to\_binary/1 for maximum performance) and configure it via a
:serializer option in the global config.

## **5.0 Advanced Capabilities and Configuration**

To be a truly effective testing tool, ReqCassette must provide powerful features
that give developers precise control over how interactions are matched,
recorded, and replayed. These capabilities are essential for handling the
complexities of real-world API integrations.

### **5.1 Comprehensive Request Matching**

The ability to accurately match a live request to a recorded one is the most
critical function of the library. The :match\_requests\_on option provides this
control, accepting a list of atoms that specify which parts of the request must
be identical. This is particularly important for APIs that use dynamic query
parameters or headers.2 **Available Matchers:**

- :method: The HTTP method (e.g., :get, :post, :put). This is almost always
  required for accurate matching.
- :uri: The full URI of the request, including the scheme, host, port, and path,
  but excluding the query string.
- :query: The query string of the URI. The matching logic will be normalized to
  be insensitive to the order of parameters (e.g., ?a=1\&b=2 will match
  ?b=2\&a=1). ExVCR documentation highlights that ignoring query parameters by
  default can lead to incorrect matches, so providing this as an explicit option
  is crucial.2
- :headers: The request headers. The matcher can be configured to require an
  exact match of all headers or to match on a specified subset of headers.
- :body: The request body. This is essential for distinguishing between
  different POST or PUT requests to the same endpoint. The matcher will
  intelligently handle common content types, for example, by parsing JSON bodies
  to be insensitive to key order.
- **Custom Matchers:** For ultimate flexibility, the :match\_requests\_on list
  will also be able to accept an anonymous function. This function will receive
  the live %Plug.Conn{} and the recorded request map as arguments and must
  return a boolean. This allows for complex, domain-specific matching logic that
  cannot be expressed with the standard matchers. Elixir \# Example of a custom
  matcher custom\_matcher \= fn live\_conn, recorded\_req \-\> \# Custom logic
  to compare live\_conn and recorded\_req live\_conn.method \==
  recorded\_req\["method"\] &&... end

  use\_cassette "custom\_match", match\_requests\_on: \[custom\_matcher\] do
  \#... end

### **5.2 Data Sanitization and Filtering**

It is imperative that sensitive data such as API keys, authentication tokens,
and personally identifiable information (PII) are not saved into cassette files
and committed to source control. ReqCassette will provide a robust,
multi-layered filtering system inspired by ExVCR's capabilities.2

- filter\_sensitive\_data(pattern, placeholder): This global configuration
  function is the primary tool for redaction. It uses a regular expression to
  find and replace sensitive values in the request URI, request body, and
  response body. For example, it can replace an API key in a query parameter or
  a token in a JSON response body.
- filter\_request\_headers(header\_name) and
  filter\_response\_headers(header\_name): These functions can be configured to
  either completely remove a specified header or to redact its value (e.g.,
  replacing the value of an Authorization header with ""). This is the
  recommended way to handle authentication tokens passed in headers.5
- **Callback-based Filtering:** The before\_record global callback provides a
  powerful escape hatch for complex filtering needs. It receives the entire
  interaction map just before it is written to disk, allowing for programmatic
  modification of any part of the request or response. This is useful for
  scenarios where simple regex replacement is insufficient, such as redacting
  nested data in a complex structure or dealing with encrypted values.

### **5.3 Dynamic Responses with Templating**

A common challenge in VCR testing is handling dynamic data in responses, such as
session tokens, nonces, or timestamps, which may be expected to change on every
request. Inspired by Ruby VCR's support for ERB templating 1, ReqCassette will
support embedding Elixir code within recorded response bodies. Mechanism: Users
can manually edit a cassette file and insert EEx-style tags (\<%=... %\>) into
the response body string.

JSON

{ "response": { "status": 200, "body": "{\\"token\\":\\"\<%=
System.unique\_integer() %\>\\",\\"expires\_at\\":\\"\<%= DateTime.utc\_now()
%\>\\"}" } }

When this interaction is replayed, the ReqCassette.Plug will pass the response
body through an EEx evaluation engine before sending it back to the client. This
evaluation will happen within the context of the before\_playback callback,
allowing for even more complex dynamic data generation. This feature enables the
simulation of stateful API interactions while still benefiting from the speed
and determinism of cassette-based testing.

## **6.0 A Comprehensive Test Plan for ReqCassette**

A testing library is only as reliable as its own test suite. To build trust and
guarantee correctness, ReqCassette must be subjected to a rigorous,
multi-layered testing strategy. This plan is not merely an internal quality
assurance process but a core part of the library's design, ensuring it can
faithfully handle the full spectrum of Req's features as explicitly requested in
the project's goals.

### **6.1 Unit Tests**

The foundation of the test suite will consist of fast, isolated unit tests with
no external dependencies (i.e., no network or filesystem access). These tests
will focus on the pure, functional components of the library. **Primary
Targets:**

- **Request Matching Logic:** Each individual matcher (:method, :uri, :query,
  :body, :headers) will be tested in isolation. For example, the :query matcher
  will be tested with various parameter combinations, including different
  orderings, to ensure it is correctly normalized. The :body matcher will be
  tested with different JSON and form-encoded payloads.
- **Data Filtering Functions:** The internal logic for filter\_sensitive\_data
  and the header filtering functions will be tested with a wide range of inputs
  to verify that redaction and removal work as expected without unintended side
  effects.
- **Cassette Serializer:** The default JSON serializer will be tested to ensure
  that encoding a cassette data structure and then decoding it results in the
  original data structure (symmetrical serialization).
- **Configuration Module:** The ReqCassette.Config module will be tested to
  ensure that global settings are correctly stored and retrieved.

### **6.2 Integration Tests**

This layer of testing will verify the core logic of the ReqCassette.Plug without
making actual network calls. These tests will focus on the interaction between
the plug's logic and the filesystem. **Methodology:**

1. **Fixture Cassettes:** A set of pre-written .json cassette files will be
   placed in the test/fixtures directory. These will represent various scenarios
   (e.g., a cassette with a single GET request, one with multiple POST requests,
   one with non-200 status codes).
2. **Manual Connection Creation:** In the tests, a %Plug.Conn{} struct
   representing an outgoing Req request will be manually constructed using
   helpers from Plug.Test, such as Plug.Test.conn/3.16
3. **Direct Plug Invocation:** The ReqCassette.Plug.call/2 function will be
   invoked directly with the manually created connection and the appropriate
   options.
4. **Assertion:** The returned %Plug.Conn{} will be inspected to assert that its
   status, headers, and body correctly match the data from the fixture cassette
   file. This approach thoroughly tests the entire replay path, including file
   I/O, JSON parsing, request matching, and response construction, in a
   controlled and network-free environment.

### **6.3 End-to-End (E2E) Tests**

This is the most critical and comprehensive testing layer. E2E tests will
validate the library's behavior in a realistic scenario, using live Req calls
against a real, albeit controlled, HTTP server. This suite serves as the
ultimate guarantee of compatibility and correctness. Technical Setup: The E2E
test suite will leverage the Bypass library to run a lightweight, in-process web
server.2 Bypass is the ideal tool for this purpose because it is itself a
Plug-based server designed specifically for testing. It allows tests to define
pre-baked responses and make assertions on the requests it receives. **Record
Path Test Flow:**

1. A test will start a Bypass instance on a random port.
2. The test will define an endpoint on the Bypass server (e.g., a POST /users
   endpoint that returns a specific JSON payload).
3. A Req call targeting the Bypass URL will be wrapped in a use\_cassette
   "e2e\_record\_test", record: :all block.
4. The Req call is executed.
5. Assertions are made to confirm that the Req.Response matches the response
   defined in Bypass.
6. After the block completes, the filesystem is checked to assert that the
   e2e\_record\_test.json cassette was created and that its contents accurately
   reflect the interaction with the Bypass server.

**Replay Path Test Flow:**

1. A separate test will use the cassette file generated by the record path test.
2. Crucially, the Bypass server will be explicitly shut down using Bypass.down/1
   before the Req call is made.19 This guarantees that any attempt to make a
   real network call will fail with a connection error.
3. The same Req call is wrapped in a use\_cassette "e2e\_record\_test", record:
   :none block.
4. The Req call is executed.
5. The test asserts that the call succeeds and that the Req.Response contains
   the correct data. This proves that the response was successfully replayed
   from the cassette, as the live server was unavailable.

Comprehensive Req Feature Coverage: The E2E suite must be exhaustive, with
specific tests designed to validate ReqCassette's handling of every major Req
feature, including but not limited to:

- All standard HTTP methods (GET, POST, PUT, PATCH, DELETE).
- Request body streaming (e.g., using Stream.map/2 as the request body).
- Response body streaming (e.g., using into: \&IO.inspect/1).
- Multipart form uploads for file submissions.
- Req's automatic redirect following (follow\_redirects step).
- All built-in authentication mechanisms (:basic, :bearer, :netrc).
- Recording and replaying of non-successful HTTP statuses (e.g., 4xx and 5xx
  errors).
- Handling of various request and response encodings.

This extensive E2E suite is more than just an internal quality check; it is a
core, public-facing feature of the library. It acts as a living, executable
specification that provides an undeniable guarantee to users that ReqCassette
correctly and faithfully captures and replays the full range of behaviors of the
Req client. This comprehensive validation is the only way to fulfill the
project's mandate and build the developer community's trust in the library's
robustness.

## **7.0 Ecosystem Positioning and Migration Guidance**

To ensure successful adoption, it is essential to clearly define ReqCassette's
place within the existing Elixir testing ecosystem and to provide a clear path
for users of older tools to migrate.

### **7.1 Comparative Analysis**

ReqCassette joins a landscape that includes other powerful testing tools like
ExVCR and Bypass. It is important to understand that these tools are not always
mutually exclusive; they are designed to solve different problems, and the
choice of which to use depends on the specific testing goal.

- **Bypass** is best used for **live, in-process stubbing**. Its purpose is to
  act as a controllable, fake server against which a client's behavior can be
  tested. With Bypass, the focus is on asserting that the client sends the
  correct request (e.g., correct path, headers, body) and on testing how the
  client reacts to various server responses (e.g., 500 errors, timeouts) that
  are explicitly defined in the test.19 It does not involve recording or
  replaying.
- **ExVCR** and **ReqCassette** are **record-and-replay** tools. Their purpose
  is to create a high-fidelity, static snapshot of a real third-party API
  interaction. The focus is not on testing the client's request-building logic
  but on providing a fast and deterministic fixture for the code that _consumes_
  the API's response.

The key recommendation is: use Bypass when you need to test the specific details
of an outgoing request or your client's resilience to server-side issues. Use
ReqCassette when you want to quickly and easily capture the complex response of
a real-world service to create a stable, offline fixture for your application's
business logic.

### **7.2 Feature and Architecture Comparison Table**

The following table provides a clear, at-a-glance comparison of the key
characteristics of ReqCassette, ExVCR, and Bypass.

| Feature / Dimension      | ReqCassette (Proposed)                  | ExVCR                                     | Bypass                                             |
| :----------------------- | :-------------------------------------- | :---------------------------------------- | :------------------------------------------------- |
| **Primary Use Case**     | Record/replay of Req calls              | Record/replay of various HTTP clients     | Live stubbing of an HTTP server                    |
| **Core Mechanism**       | Req.Test with a custom Plug             | :meck for global function patching        | In-process OTP application (web server)            |
| **Concurrency Safety**   | ✅ **Yes** (async: true safe)           | ❌ **No** (Often requires async: false) 4 | ✅ **Yes** (async: true safe)                      |
| **Target Client**        | Req only                                | hackney, ibrowse, finch, etc. 2           | Any HTTP client                                    |
| **Setup Complexity**     | Low (Global config in test\_helper.exs) | Medium (Per-test config, adapter setup)   | Low (Start in test setup block)                    |
| **Network Dependency**   | Only for initial recording              | Only for initial recording                | None (acts as the server)                          |
| **Assertion on Request** | No (Asserts on client-side code)        | No (Asserts on client-side code)          | Yes (Bypass.expect asserts on received request) 19 |

### **7.3 Migration Guide from ExVCR**

For teams currently using ExVCR with Req (via its hackney or finch adapters) who
wish to migrate to ReqCassette, the process is designed to be straightforward.

- **Step 1: Dependency Change:** In mix.exs, replace {:exvcr,...} with
  {:req\_cassette,...} in the :test dependencies and run mix deps.get.
- **Step 2: Code Updates:** In your test modules, replace use ExVCR.Mock,...
  with use ReqCassette. The use\_cassette macro is designed to be syntactically
  similar, so most calls should require minimal changes.
- **Step 3: Configuration Migration:** Move any configuration logic from setup
  blocks (e.g., ExVCR.Config.cassette\_library\_dir(...)) to a centralized
  ReqCassette.Config.setup(...) call in test/test\_helper.exs.
- **Step 4: Cassette Regeneration:** While both libraries use JSON, the internal
  schema and structure will likely differ. The most reliable migration path is
  to delete the old ExVCR cassettes (using mix vcr.delete or manually) and allow
  ReqCassette to re-record them on the next test run. This ensures the new
  cassettes are perfectly aligned with ReqCassette's format and matching logic.
- **Step 5: Enable Asynchronous Testing:** The final and most impactful step is
  to change use ExUnit.Case, async: false to use ExUnit.Case, async: true in the
  migrated test modules. This will unlock the full performance benefits of
  parallel test execution, which is one of the primary advantages of adopting
  ReqCassette.

#### **Works cited**

1. vcr/vcr: Record your test suite's HTTP interactions and replay them during
   future test runs for fast, deterministic, accurate tests. \- GitHub, accessed
   October 10, 2025, [https://github.com/vcr/vcr](https://github.com/vcr/vcr)
2. ExVCR — exvcr v0.17.1 \- HexDocs, accessed October 10, 2025,
   [https://hexdocs.pm/exvcr/](https://hexdocs.pm/exvcr/)
3. Testing HTTP Requests in Elixir with ExVCR Library Guide \- Curiosum,
   accessed October 10, 2025,
   [https://www.curiosum.com/blog/test-http-requests-in-elixir-with-exvcr](https://www.curiosum.com/blog/test-http-requests-in-elixir-with-exvcr)
4. VCR vs ExUnit Tags \- Questions / Help \- Elixir Programming Language Forum,
   accessed October 10, 2025,
   [https://elixirforum.com/t/vcr-vs-exunit-tags/24366](https://elixirforum.com/t/vcr-vs-exunit-tags/24366)
5. HTTP unit tests using ExVCR \- Binary Consulting, accessed October 10, 2025,
   [https://10consulting.com/2016/11/07/http-unit-tests-in-elixir-using-exvcr/](https://10consulting.com/2016/11/07/http-unit-tests-in-elixir-using-exvcr/)
6. parroty/exvcr: HTTP request/response recording library for ... \- GitHub,
   accessed October 10, 2025,
   [https://github.com/parroty/exvcr](https://github.com/parroty/exvcr)
7. meck vs ExVCR | LibHunt \- Awesome Elixir, accessed October 10, 2025,
   [https://elixir.libhunt.com/compare-meck-vs-exvcr](https://elixir.libhunt.com/compare-meck-vs-exvcr)
8. req v0.5.15 \- HexDocs, accessed October 10, 2025,
   [https://hexdocs.pm/req/](https://hexdocs.pm/req/)
9. req v0.5.15 \- HexDocs, accessed October 10, 2025,
   [https://hexdocs.pm/req/Req.html](https://hexdocs.pm/req/Req.html)
10. Req.Test — req v0.5.15 \- HexDocs, accessed October 10, 2025,
    [https://hexdocs.pm/req/Req.Test.html](https://hexdocs.pm/req/Req.Test.html)
11. Plug \- Elixir School, accessed October 10, 2025,
    [https://elixirschool.com/en/lessons/misc/plug](https://elixirschool.com/en/lessons/misc/plug)
12. Plug v1.18.1 \- HexDocs, accessed October 10, 2025,
    [https://hexdocs.pm/plug/](https://hexdocs.pm/plug/)
13. Req API Client Testing \- Dashbit Blog, accessed October 10, 2025,
    [https://dashbit.co/blog/req-api-client-testing](https://dashbit.co/blog/req-api-client-testing)
14. Testing HTTP API Clients in Elixir using Req, accessed October 10, 2025,
    [https://elixirmerge.com/p/testing-http-api-clients-in-elixir-using-req](https://elixirmerge.com/p/testing-http-api-clients-in-elixir-using-req)
15. Unable to instruct ExVCR to records two PUT requests \- Questions / Help \-
    Elixir Forum, accessed October 10, 2025,
    [https://elixirforum.com/t/unable-to-instruct-exvcr-to-records-two-put-requests/38681](https://elixirforum.com/t/unable-to-instruct-exvcr-to-records-two-put-requests/38681)
16. Testing Elixir Plugs \- Thoughtbot, accessed October 10, 2025,
    [https://thoughtbot.com/blog/testing-elixir-plugs](https://thoughtbot.com/blog/testing-elixir-plugs)
17. Phoenix/Elixir: How to set the action in a test connection with
    Plug.Test.conn()?, accessed October 10, 2025,
    [https://stackoverflow.com/questions/38655990/phoenix-elixir-how-to-set-the-action-in-a-test-connection-with-plug-test-conn](https://stackoverflow.com/questions/38655990/phoenix-elixir-how-to-set-the-action-in-a-test-connection-with-plug-test-conn)
18. elixir-plug/plug: Compose web applications with functions \- GitHub,
    accessed October 10, 2025,
    [https://github.com/elixir-plug/plug](https://github.com/elixir-plug/plug)
19. Bypass \- Elixir School, accessed October 10, 2025,
    [https://elixirschool.com/en/lessons/testing/bypass](https://elixirschool.com/en/lessons/testing/bypass)
20. bypass v2.1.0 \- HexDocs, accessed October 10, 2025,
    [https://hexdocs.pm/bypass/Bypass.html](https://hexdocs.pm/bypass/Bypass.html)

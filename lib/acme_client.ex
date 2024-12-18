defmodule AcmeClient do
  @moduledoc """

  Public client interface.

  From https://datatracker.ietf.org/doc/html/rfc8555

    +-------------------+--------------------------------+--------------+
    | Action            | Request                        | Response     |
    +-------------------+--------------------------------+--------------+
    | Get directory     | GET  directory                 | 200          |
    |                   |                                |              |
    | Get nonce         | HEAD newNonce                  | 200          |
    |                   |                                |              |
    | Create account    | POST newAccount                | 201 ->       |
    |                   |                                | account      |
    |                   |                                |              |
    | Submit order      | POST newOrder                  | 201 -> order |
    |                   |                                |              |
    | Fetch challenges  | POST-as-GET order's            | 200          |
    |                   | authorization urls             |              |
    |                   |                                |              |
    | Respond to        | POST authorization challenge   | 200          |
    | challenges        | urls                           |              |
    |                   |                                |              |
    | Poll for status   | POST-as-GET order              | 200          |
    |                   |                                |              |
    | Finalize order    | POST order's finalize url      | 200          |
    |                   |                                |              |
    | Poll for status   | POST-as-GET order              | 200          |
    |                   |                                |              |
    | Download          | POST-as-GET order's            | 200          |
    | certificate       | certificate url                |              |
    +-------------------+--------------------------------+--------------+
  """
  alias AcmeClient.Session

  require Logger

  @app :acme_client

  @type code :: non_neg_integer()
  @type client :: Req.Request.t()
  @type reason :: any()
  @type nonce :: binary()
  @type request_ret ::
          {:ok, Session.t(), term()} | {:error, Session.t(), term()} | {:error, term()}
  @type object_ret :: {:ok, Session.t(), map()} | {:error, Session.t(), term()} | {:error, term()}
  @type string_ret :: {:ok, Session.t(), map()} | {:error, Session.t(), term()} | {:error, term()}

  @type headers :: list({binary(), binary()})

  @rate_limit_id "http"
  @rate_limit_scale 1000
  # @rate_limit_limit 5
  @rate_limit_limit 10

  @doc ~S"""
  Create new session connecting to ACME server."

  Sets up the Req client library, then makes an API call to the server's
  directory URL which maps standard names for operations to the specific URLs
  on the server.

  Options:

  * directory_url: Server directory URL.
                   Defaults to production server `https://acme-v02.api.letsencrypt.org/directory`,
                   Staging is `https://acme-staging-v02.api.letsencrypt.org/directory`

  * account_key: ACME account key (optional)
  * account_kid: ACME account key id, a URL (optional)

  ## Examples

    {:ok, account_key} = AcmeClient.generate_account_key()
    contact = "mailto:admin@example.com"
    {:ok, session, account} = AcmeClient.new_account(account_key: account_key, contact: contact)

    {:ok, session} = AcmeClient.new_session(account_key: account_key, account_kid: account_kid)
    {:ok, session} = AcmeClient.new_nonce(session)
  """
  @spec new_session(Keyword.t()) :: {:ok, Session.t()} | {:error, term()}
  def new_session(opts \\ []) do
    directory_url =
      opts
      |> Keyword.fetch(:directory_url)
      |> case do
        {:ok, value} -> value
        :error -> "https://acme-v02.api.letsencrypt.org/directory"
      end

    client =
      case Keyword.fetch(opts, :client) do
        {:ok, client} -> client
        :error -> Req.new()
      end

    session = %Session{
      account_key: opts[:account_key],
      account_kid: opts[:account_kid],
      directory: opts[:directory],
      rate_limit_id: opts[:rate_limit_id] || @rate_limit_id,
      rate_limit_scale: opts[:rate_limit_scale] || @rate_limit_scale,
      rate_limit_limit: opts[:rate_limit_limit] || @rate_limit_limit,
      client: client
    }

    case Req.request(client, method: :get, url: directory_url) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, %{session | directory: body, client: client}}

      {:ok, %Req.Response{} = response} ->
        {:error, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc ~S"""
  Get nonce from server and add it to session.

  Each call to the server API must have a nonce to prevent replays.
  Normally the response from the API has a nonce which is used for the next
  call. The first call needs a nonce, so use this function to get it.
  Similarly, if the nonce is no longer valid, this function gets a new one.
  """
  @spec new_nonce(Session.t()) ::
          {:ok, Session.t()} | {:error, Session.t(), :throttled} | {:error, term()}
  def new_nonce(session) do
    case ExRated.check_rate("nonce", 1000, 20) do
      {:ok, _count} ->
        url = session.directory["newNonce"]

        case Req.request(session.client, method: :head, url: url) do
          {:ok, %Req.Response{status: 200} = response} ->
            {:ok, set_nonce(session, response)}

          {:ok, response} ->
            {:error, response}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _limit} ->
        {:error, session, :throttled}
    end
  end

  @doc ~S"""
  Convenience function which creates a session configured from app environment.

  Options:
    * directory_url (optional)
    * account_key: Account key (optional)
    * account_kid: Account key id URL (optional)

  If options are not specified, they are read from the environment, e.g.:

    config :acme_client,
      directory_url:
        System.get_env("ACME_CLIENT_DIRECTORY_URL") || "https://acme-staging-v02.api.letsencrypt.org/directory",
      account_key: System.get_env("ACME_CLIENT_ACCOUNT_KEY"),
      account_kid: System.get_env("ACME_CLIENT_ACCOUNT_KID")

  ## Examples

    {:ok, session} = AcmeClient.create_session()
  """
  @spec create_session(Keyword.t()) ::
          {:ok, Session.t()} | {:error, Session.t(), :throttled} | {:error, term()}
  def create_session(opts \\ []) do
    key =
      case Keyword.fetch(opts, :account_key) do
        {:ok, value} ->
          value

        :error ->
          account_key_bin = Application.get_env(@app, :account_key)
          AcmeClient.binary_to_key(account_key_bin)
      end

    session_opts = [
      directory_url: opts[:directory_url] || Application.get_env(@app, :directory_url),
      directory: opts[:directory] || Application.get_env(@app, :directory),
      account_kid: opts[:account_kid] || Application.get_env(@app, :account_kid),
      account_key: key,
      rate_limit_id:
        opts[:rate_limit_id] || Application.get_env(@app, :rate_limit_id, @rate_limit_id),
      rate_limit_scale:
        opts[:rate_limit_scale] || Application.get_env(@app, :rate_limit_scale, @rate_limit_scale),
      rate_limit_limit:
        opts[:rate_limit_limit] || Application.get_env(@app, :rate_limit_limit, @rate_limit_limit)
    ]

    with {:ok, session} <- new_session(session_opts),
         {:ok, session} <- new_nonce(session) do
      {:ok, session}
    else
      err -> err
    end
  end

  @doc ~S"""
  Perform POST-as-GET HTTP call.

  This reads a URL from the server. Instead of using GET, it uses POST so that the
  request has the proper signing and nonce.

  ## Examples
    {:ok, session, response} = AcmeClient.post_as_get(session, "https://acme-staging-v02.api.letsencrypt.org/acme/acct/123")
  """
  @spec post_as_get(Session.t(), binary()) :: request_ret()
  def post_as_get(session, url, payload \\ "") do
    case ExRated.check_rate(
           session.rate_limit_id,
           session.rate_limit_scale,
           session.rate_limit_limit
         ) do
      {:ok, _count} ->
        %{client: client, account_key: account_key, account_kid: kid, nonce: nonce} = session

        protected = %{"alg" => "ES256", "kid" => kid, "nonce" => nonce, "url" => url}
        {_, body} = JOSE.JWS.sign(account_key, payload, protected)

        case Req.request(client,
               method: :post,
               url: url,
               headers: %{content_type: "application/jose+json"},
               json: body
             ) do
          {:ok, %Req.Response{status: 200} = response} ->
            session = set_nonce(session, response)
            {:ok, session, response}

          {:ok,
           %Req.Response{
             status: 400,
             body: %{"type" => "urn:ietf:params:acme:error:badNonce"}
           } = response} ->
            session = set_nonce(session, response)
            post_as_get(session, url, payload)

          {:ok, %Req.Response{} = response} ->
            {:error, set_nonce(session, response), response}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _limit} ->
        {:error, session, :throttled}
    end
  end

  # TODO: use get_object instead
  @spec get_order(Session.t(), binary()) :: object_ret()
  def get_order(session, url) do
    case post_as_get(session, url) do
      {:ok, session, response} ->
        {:ok, session, response.body}

      error ->
        error
    end
  end

  @doc "Convenience function to call URL and get result body map."
  @spec get_object(Session.t(), binary()) :: object_ret()
  def get_object(session, url) do
    case post_as_get(session, url) do
      {:ok, session, response} ->
        {:ok, session, response.body}

      error ->
        error
    end
  end

  # @doc ~S"""
  # Get a list of URLs with post_as_get.
  # """
  # @spec get_urls(Session.t(), list(binary())) :: {:ok, Session.t(), term()}
  # def get_urls(session, urls) do
  #   {session, results} =
  #     Enum.reduce(urls, {session, []}, fn url, {session, acc} ->
  #       {:ok, session, result} = AcmeClient.post_as_get(session, url)
  #       {session, [{url, result.body} | acc]}
  #     end)
  #
  #   {:ok, session, Enum.reverse(results)}
  # end

  @doc ~S"""
  Get contents of a list of URLs with post_as_get.

  Reads a list of URLs with post_as_get, returning a list of results.
  If an error occurs, stops and returns the error message.
  """
  @spec get_urls(Session.t(), [binary()]) ::
          {:ok, Session.t(), list({binary(), map()})}
          | {:error, term()}
  def get_urls(session, urls) do
    Logger.debug("urls: #{inspect(urls)}")

    {session, results} =
      Enum.reduce(urls, {session, []}, fn
        _url, {nil, results} ->
          {nil, results}

        url, {session, results} ->
          Logger.debug("Getting #{url}")

          case AcmeClient.post_as_get(session, url) do
            {:ok, session, response} ->
              {session, [{url, response.body} | results]}

            {:error, _session, reason} ->
              {nil, [{url, {:error, reason}} | results]}

              {:error, reason}
              {nil, [{url, {:error, reason}} | results]}
          end
      end)

    case {session, results} do
      {nil, [{_url, error} | _rest]} ->
        error

      {session, results} ->
        {:ok, session, results}
    end
  end

  # @doc "Get status of url."
  # @spec get_status(Session.t(), binary()) :: string_ret()
  # def get_status(session, url) do
  #   case post_as_get(session, url) do
  #     {:ok, session, result} ->
  #       {:ok, session, result.body["status"]}
  #
  #     error ->
  #       error
  #   end
  # end

  @doc "Make request to URL to tell server it can start processing."
  @spec poke_url(Session.t(), binary()) :: request_ret()
  def poke_url(session, url) do
    post_as_get(session, url, "{}")
  end

  @doc ~S"""
  Generate JWS cryptographic key for account.
  """
  @spec generate_account_key(Keyword.t()) :: {:ok, JOSE.JWK.t()}
  def generate_account_key(opts \\ []) do
    alg = opts[:alg] || "ES256"
    {:ok, JOSE.JWS.generate_key(%{"alg" => alg})}
  end

  # def generate_account_key(opts) do
  #   key_size = opts[:key_size] || 2048
  #   JOSE.JWK.generate_key({:rsa, key_size})
  # end

  @doc ~S"""
  Create new ACME account.

  Options:
    * account_key: Account key, from `generate_account_key/1`
    * contact: Account owner contact(s), e.g. "mailto:jake@cogini.com", string
               or array of strings.
    * terms_of_service_agreed: true (optional)
    * only_return_existing: true (optional)
    * external_account_binding: associated external account (optional)

  ## Examples

    {:ok, account_key} = AcmeClient.generate_account_key()
    opts = [
      account_key: account_key,
      contact: "mailto:admin@example.com",
      terms_of_service_agreed: true,
    ]
    {:ok, session} = AcmeClient.new_session()
    {:ok, session} = AcmeClient.new_nonce(session)
    {:ok, session, account} = AcmeClient.new_account(session, opts)
  """
  @spec new_account(Session.t(), Keyword.t()) ::
          {:ok, Session.t(), map()}
          # | {:error, Session.t(), Tesla.Env.result()}
          | {:error, term()}
  def new_account(session, opts) do
    %{client: client, account_key: account_key, nonce: nonce} = session
    url = session.directory["newAccount"]

    map_opts =
      fn
        {:contact, value} = pair when is_list(value) -> pair
        {:contact, value} when is_binary(value) -> {:contact, [value]}
        {:terms_of_service_agreed, true} -> {"termsOfServiceAgreed", true}
        {:only_return_existing, true} -> {"onlyReturnExisting", true}
        {:external_account_binding, value} -> {"externalAccountBinding", value}
      end

    opts_keys = [
      :contact,
      :terms_of_service_agreed,
      :only_return_existing,
      :external_account_binding
    ]

    payload =
      opts
      |> Keyword.take(opts_keys)
      |> Map.new(map_opts)
      |> Jason.encode!()

    protected = %{"alg" => "ES256", "nonce" => nonce, "url" => url, jwk: key_to_jwk(account_key)}
    {_, body} = JOSE.JWS.sign(account_key, payload, protected)

    case Req.request(client,
           method: :post,
           url: url,
           headers: %{content_type: "application/jose+json"},
           json: body
         ) do
      # Returns 201 on initial create, 200 if called again
      {:ok, %Req.Response{status: status} = response} when status in [200, 201] ->
        session = set_nonce(session, response)
        [location] = Req.Response.get_header(response, "location")

        {:ok, %{session | account_kid: location},
         %{
           object: response.body,
           url: location
         }}

      {:ok, %Req.Response{} = response} ->
        {:error, set_nonce(session, response), response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc ~S"""
  Create HTTP challenge URL for token.

  https://datatracker.ietf.org/doc/html/rfc8555#section-8.3

  Response:

    HTTP/1.1 200 OK
    Content-Type: application/octet-stream

    <key_authorization>
  """
  @spec http_challenge_url(binary()) :: binary()
  def http_challenge_url(token) do
    "/.well-known/acme-challenge/" <> token
  end

  @doc ~S"""
  Create key authorization from token and key.

  https://datatracker.ietf.org/doc/html/rfc8555#section-8.1
  """
  @spec key_authorization(binary(), JOSE.JWK.t()) :: binary()
  def key_authorization(token, key) do
    token <> "." <> key_thumbprint(key)
  end

  @doc ~S"""
  Generate RFC7638 thumbprint of key.

  https://datatracker.ietf.org/doc/html/rfc7638

  ## Examples

    AcmeClient.key_thumbprint(account_key)
  """
  @spec key_thumbprint(JOSE.JWK.t()) :: binary()
  def key_thumbprint(key) do
    key
    |> JOSE.JWK.to_thumbprint_map()
    |> JOSE.JWK.thumbprint()
  end

  @doc ~S"""
  Generate DNS challenge response.

  https://datatracker.ietf.org/doc/html/rfc8555#section-8.4

    _acme-challenge.www.example.org. 300 IN TXT "<key_authorization>"

  """
  def dns_challenge_response(token, key) do
    token
    |> key_authorization(key)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  def dns_challenge_name(%{"type" => "dns", "value" => domain}) do
    "_acme-challenge." <> domain
  end

  def dns_challenge_name("*." <> domain) do
    "_acme-challenge." <> domain
  end

  def dns_challenge_name(domain) when is_binary(domain) do
    "_acme-challenge." <> domain
  end

  @spec dns_validate(map(), Keyword.t()) :: list(binary())
  def dns_validate(authorization, opts \\ []) do
    %{"identifier" => identifier} = authorization
    host = dns_challenge_name(identifier)

    case :inet_res.lookup(to_charlist(host), :in, :txt, opts) do
      [] ->
        authorization

      values ->
        for [value | _rest] <- values, do: to_string(value)
    end
  end

  @doc "Get TXT records for host or empty list on failure"
  @spec dns_txt_records(binary(), Keyword.t()) :: list(binary())
  def dns_txt_records(host, opts \\ []) do
    case :inet_res.lookup(to_charlist(host), :in, :txt, opts) do
      [] ->
        []

      values ->
        for [value | _rest] <- values, do: to_string(value)
    end
  end

  @doc "Get NS records for domain or empty list on failure"
  @spec dns_ns_records(binary(), Keyword.t()) :: list(binary())
  def dns_ns_records(domain, opts \\ []) do
    case :inet_res.lookup(to_charlist(domain), :in, :ns, opts) do
      [] ->
        []

      values ->
        for [value | _rest] <- values, do: to_string(value)
    end
  end

  @doc ~S"""
  Create new order.

  Options:

  * identifiers: domain(s), either binary value, type/value map, or list of binary values/maps
  * not_before: datetime in RFC3339 (ISO8601) format (optional), not supported by Let's Encrypt
  * not_after: datetime in RFC3339 (ISO8601) format (optional), not supported by Let's Encrypt

  The type/value map specifies the domain, e.g., `%{type: "dns", value: "example.com"}`

  `account_key` and `account_kid` must be set in the session.

  On success, returns map where `url` is the URL of the created order and
  `object` has its attributes. Make sure to keep track of the URL, or it may be
  impossible to complete the order. The Let's Encrypt API does not support the
  ability to get the outstanding orders for an acount, as specified in RFC8555.

  ## Examples
    AcmeClient.new_order(session, identifiers: ["example.com", "*.example.com"])
  """
  @spec new_order(Session.t(), Keyword.t()) :: object_ret()
  def new_order(session, opts) do
    %{client: client, account_key: account_key, account_kid: kid, nonce: nonce} = session
    url = session.directory["newOrder"]

    # Convert string identifier to DNS map
    map_identifier =
      fn
        value when is_binary(value) -> %{type: "dns", value: value}
        value when is_map(value) -> value
      end

    # Convert input opts
    map_opts =
      fn
        {:identifiers, value} when is_binary(value) ->
          {:identifiers, [%{type: "dns", value: value}]}

        {:identifiers, value} when is_map(value) ->
          {:identifiers, [value]}

        {:identifiers, values} when is_list(values) ->
          {:identifiers, Enum.map(values, map_identifier)}

        {:not_before, value} when is_binary(value) ->
          {"notBefore", value}

        {:not_after, value} when is_binary(value) ->
          {"notAfter", value}
      end

    payload =
      opts
      |> Keyword.take([:identifiers, :not_before, :not_after])
      |> Map.new(map_opts)
      |> Jason.encode!()

    protected = %{"alg" => "ES256", "kid" => kid, "nonce" => nonce, "url" => url}
    {_, body} = JOSE.JWS.sign(account_key, payload, protected)

    case Req.request(client,
           method: :post,
           url: url,
           headers: %{content_type: "application/jose+json"},
           json: body
         ) do
      {:ok, %Req.Response{status: status} = result} when status in [201, 200] ->
        session = set_nonce(session, result)

        value = %{
          object: result.body,
          url: Req.Response.get_header(result, "location")
        }

        {:ok, session, value}

      {:ok, %Req.Response{} = result} ->
        {:error, set_nonce(session, result), result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc ~S"""
  Create challenge responses for order authorizations.

  ## Examples

    {:ok, session, authorizations} = AcmeClient.create_challenge_responses(session, order.object)
  """
  @spec create_challenge_responses(Session.t(), map()) ::
          {:ok, Session.t(), list({binary(), map()})} | {:error, term()}
  def create_challenge_responses(session, order) do
    key = session.account_key

    case AcmeClient.get_urls(session, order["authorizations"]) do
      {:ok, session, authorizations} ->
        authorizations =
          for {url, authorization} <- authorizations do
            {url, create_authorization_response(authorization, key)}
          end

        {:ok, session, authorizations}

        # err ->
        #   err
    end
  end

  # Generate challenge respones and add to authorization map
  # https://letsencrypt.org/docs/challenge-types/
  @spec create_authorization_response(map(), binary()) :: map()
  defp create_authorization_response(authorization, key) do
    challenges =
      for challenge <- authorization["challenges"] do
        challenge_add_response(challenge, key)
      end

    Map.put(authorization, "challenges", challenges)
  end

  def challenge_add_response(%{"type" => "dns-01", "token" => token} = challenge, key) do
    Map.put(challenge, "response", dns_challenge_response(token, key))
  end

  def challenge_add_response(%{"type" => "http-01", "token" => token} = challenge, key) do
    Map.put(challenge, "response", key_authorization(token, key))
  end

  def challenge_add_response(challenge, _key), do: challenge

  @doc ~S"""
  Convenience function which creates an order and authorizations.

  Takes the same options as `new_order/2`

  ## Examples

    {:ok, session, {order, authorizations}} = AcmeClient.create_order(session, identifiers: ["example.com", "*.example.com"])
  """
  @spec create_order(Session.t(), Keyword.t()) :: request_ret()
  def create_order(session, opts) do
    with {:ok, session, order} <- AcmeClient.new_order(session, opts),
         {:ok, session, authorizations} <-
           AcmeClient.create_challenge_responses(session, order.object) do
      {:ok, session, {order, authorizations}}
    else
      err -> err
    end
  end

  # {
  #   "type": "urn:ietf:params:acme:error:badNonce",
  #   "detail": "JWS has an invalid anti-replay nonce: \"0002t4XOF7rhtseQk6TdCqyU-Sk1U6l-gK9M2_aHT3We1bo\"",
  #   "status": 400
  # }

  # status: 429
  # %{
  #   "detail" => "Rate limit for '/directory' reached",
  #   "type" => "urn:ietf:params:acme:error:rateLimited"
  # },

  # status: 429
  # %{
  #   "detail" => "Rate limit for '/acme' reached",
  #   "type" => "urn:ietf:params:acme:error:rateLimited"
  # },

  @doc ~S"""
  Create Req client.

  Options are:

  * base_url: URL of server (optional), default "https://acme-staging-v02.api.letsencrypt.org/directory"
  """
  @spec create_client(Keyword.t()) :: Req.Request.t()
  def create_client(opts \\ []) do
    base_url = opts[:base_url] || "https://acme-staging-v02.api.letsencrypt.org/directory"

    Req.new(base_url: base_url)
  end

  @spec get_directory(Req.Request.t()) :: {:ok, map()} | {:error, map()}
  def get_directory(%Req.Request{} = client) do
    do_get(client, "/directory")
  end

  # Internal utility functions

  # Set session nonce from server response headers
  @spec set_nonce(Session.t(), Req.Response.t()) :: Session.t()
  defp set_nonce(session, %Req.Response{} = response) do
    %{session | nonce: extract_nonce(response)}
  end

  @doc "Get nonce from headers"
  @spec extract_nonce(Req.Response.t()) :: binary() | nil
  def extract_nonce(%Req.Response{} = response) do
    [replay_nonce] = Req.Response.get_header(response, "replay-nonce")
    replay_nonce
  end

  @spec update_nonce(Session.t(), Req.Response.t()) :: Session.t()
  def update_nonce(session, %Req.Response{} = response) do
    %{session | nonce: extract_nonce(response)}
  end

  # Convert account key to JWK representation used in API
  defp key_to_jwk(account_key) do
    {_modules, public_map} = JOSE.JWK.to_public_map(account_key)
    public_map
  end

  @doc "Convert account_key struct to binary."
  def key_to_binary(key) do
    {_type, value} = JOSE.JWK.to_binary(key)
    value
  end

  @doc "Convert binary to account_key struct."
  def binary_to_key(bin) do
    JOSE.JWK.from_binary(bin)
  end

  @spec do_get(Req.Request.t(), binary()) :: {:ok, map()} | {:error, map()}
  def do_get(%Req.Request{} = client, url) do
    req_response(Req.get(client, url))
  end

  defp req_response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}

  defp req_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, %{status: status, body: body}}

  defp req_response({:error, reason}), do: {:error, %{status: 0, reason: reason}}

  @spec request(client(), Session.t(), Keyword.t()) :: request_ret()
  def request(client, session, options \\ []) do
    default_options = [
      method: :post,
      status: 200
    ]

    options = Keyword.merge(default_options, options)
    {status, options} = Keyword.pop(options, :status)

    Logger.debug("client: #{inspect(client)}")
    Logger.debug("session: #{inspect(session)}")
    Logger.debug("options: #{inspect(options)}")
    Logger.debug("status: #{inspect(status)}")

    case Req.request(client, options) do
      {:ok, %{status: ^status} = result} ->
        {:ok, set_nonce(session, result), result}

      {:ok, result} ->
        {:error, set_nonce(session, result), result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # https://letsencrypt.org/docs/rate-limits/
  # 300 New Orders per account per 3 hours

  # urn:ietf:params:acme:error:rateLimited
  # Retry-After = HTTP-date / delay-seconds
  # A delay-seconds value is a non-negative decimal integer, representing time in seconds.

  #  Retry-After: Fri, 31 Dec 1999 23:59:59 GMT
  #  Retry-After: 120
end

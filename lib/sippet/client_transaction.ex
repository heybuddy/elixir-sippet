defmodule Sippet.ClientTransaction do
  alias Sippet.Message, as: Message
  alias Sippet.Message.RequestLine, as: RequestLine
  alias Sippet.Message.StatusLine, as: StatusLine
  alias Sippet.ClientTransaction.Invite, as: Invite
  alias Sippet.ClientTransaction.NonInvite, as: NonInvite

  def get_module(%Message{start_line: %RequestLine{method: method}}) do
    case method do
      :invite -> Invite
      _otherwise -> NonInvite
    end
  end

  def on_response(transaction, %Message{start_line: %StatusLine{}} = response)
      when is_pid(transaction) do
    :gen_statem.cast(transaction, {:incoming_response, response})
  end
end

defmodule Sippet.ClientTransaction.Invite do
  use Sippet.Transaction, tag: 'invite/client', initial_state: :calling

  alias Sippet.Transport, as: Transport
  alias Sippet.Message.StatusLine, as: StatusLine

  @timer_a 600  # optimization: transaction ends in 37.8s
  @timer_b 64 * @timer_a
  @timer_d 32000  # timer D should be > 32s

  defp retry({past_wait, passed_time}, %{request: request}) do
    Transport.Registry.send(request)
    new_delay = past_wait * 2
    {:keep_state_and_data, [{:state_timeout, new_delay,
       {new_delay, passed_time + new_delay}}]}
  end

  defp do_build_ack(request, last_response) do
    ack =
      Message.build_request(:ack, request.start_line.request_uri)
      |> Message.put_header(:via, Message.get_header(request, :via))
      |> Message.put_header(:max_forwards, 70)
      |> Message.put_header(:from, Message.get_header(request, :from))
      |> Message.put_header(:to, Message.get_header(request, :to))
      |> Message.put_header(:call_id, Message.get_header(request, :call_id))

    {sequence, _method} = request.headers.cseq
    ack = ack |> Message.put_header(:cseq, {sequence, :ack})

    ack =
      if Message.has_header?(request, :route) do
        ack |> Message.put_header(:route, Message.get_header(request, :route))
      else
        ack
      end

    {_, _, %{"tag": to_tag}} = last_response.headers.to
    {display_name, uri, params} = Message.get_header(ack, :to)
    params = Map.put(params, "tag", to_tag)
    ack |> Message.put_header(:to, {display_name, uri, params})
  end

  def calling(:enter, _old_state, %{request: request}) do
    Transport.Registry.send(request)

    actions =
      if Transport.Registry.reliable(request) do
        [{:state_timeout, @timer_b, {@timer_b, @timer_b}}]
      else
        [{:state_timeout, @timer_a, {@timer_a, @timer_a}}]
      end

    {:keep_state_and_data, actions}
  end

  def calling(:state_timeout, {_past_wait, passed_time} = time_event, data) do
    if passed_time >= @timer_b do
      timeout(data)
    else
      retry(time_event, data)
    end
  end

  def calling(:cast, {:incoming_response, response}, data) do
    receive_response(response)
    case StatusLine.status_code_class(response.start_line) do
      1 -> {:next_state, :proceeding, data}
      2 -> {:stop, :normal, data}
      _ -> {:next_state, :completed, data}
    end
  end

  def calling(event_type, event_content, data),
    do: handle_event(event_type, event_content, data)

  def proceeding(:enter, _old_state, _data),
    do: :keep_state_and_data

  def proceeding(:cast, {:incoming_response, response}, data) do
    receive_response(response)
    case StatusLine.status_code_class(response.start_line) do
      1 -> :keep_state_and_data
      2 -> {:stop, :normal, data}
      _ -> {:next_state, :completed, data}
    end
  end

  def proceeding(event_type, event_content, data),
    do: handle_event(event_type, event_content, data)

  def completed(:enter, _old_state,
      %{request: request, last_response: last_response} = data) do
    ack = do_build_ack(request, last_response)
    data = Map.put(data, :ack, ack)
    Transport.Registry.send(ack)

    if Transport.Registry.reliable(request) do
      {:stop, :normal, data}
    else
      {:keep_state_and_data, [{:state_timeout, @timer_d, nil}]}
    end
  end

  def completed(:cast, {:incoming_response, response}, %{ack: ack}) do
    if StatusLine.status_code_class(response.start_line) >= 3 do
      Transport.Registry.send(ack)
    end
    :keep_state_and_data
  end

  def completed(:state_timeout, _nil, data),
    do: {:stop, :normal, data}

  def completed(event_type, event_content, data),
    do: handle_event(event_type, event_content, data)

  def handle_event(:cast, {:error, reason}, _state, data),
    do: shutdown(reason, data)

  def handle_event(event_type, event_content, data),
    do: unhandled_event(event_type, event_content, data)
end

defmodule Sippet.ClientTransaction.NonInvite do
  use Sippet.Transaction, tag: 'non-invite/client', initial_state: :trying

  alias Sippet.Transport, as: Transport
  alias Sippet.Message.StatusLine, as: StatusLine

  @t2 4000
  @timer_e 500
  @timer_f 64 * @timer_e
  @timer_k 5000  # timer K is 5s

  defp start_timers(%{request: request} = data) do
    data = Map.put(data, :deadline_timer,
        :erlang.start_timer(@timer_f, self(), :deadline))

    if Transport.Registry.reliable(request) do
      data
    else
      Map.put(data, :retry_timer,
          :erlang.start_timer(@timer_e, self(), @timer_e))
    end
  end

  defp cancel_timers(data) do
    case data do
      %{deadline_timer: deadline_timer} ->
        :erlang.cancel_timer(deadline_timer)
    end
    case data do
      %{retry_timer: retry_timer} ->
        :erlang.cancel_timer(retry_timer)
    end
    Map.drop(data, [:deadline_timer, :retry_timer])
  end

  defp retry(next_wait, %{request: request} = data) do
    Transport.Registry.send(request)
    data = %{data | retry_timer:
        :erlang.start_timer(next_wait, self(), next_wait)}
    {:keep_state, data}
  end

  def trying(:enter, _old_state,
      %{request: request} = data) do
    Transport.Registry.send(request)
    data = start_timers(data)
    {:keep_state, data}
  end

  def trying(:info, {:timeout, _timer, :deadline}, data),
    do: timeout(data)

  def trying(:info, {:timeout, _timer, last_delay}, data),
    do: retry(min(last_delay * 2, @t2), data)

  def trying(:cast, {:incoming_response, response}, data) do
    receive_response(response)
    case StatusLine.status_code_class(response.start_line) do
      1 -> {:next_state, :proceeding, data}
      _ -> {:next_state, :completed, data}
    end
  end

  def trying(:cast, {:error, reason}, data),
    do: shutdown(reason, data)

  def trying(event_type, event_content, data),
    do: handle_event(event_type, event_content, data)

  def proceeding(:enter, _old_state, _data),
    do: :keep_state_and_data

  def proceeding(:info, {:timeout, _timer, :deadline}, data),
    do: timeout(data)

  def proceeding(:info, {:timeout, _timer, _last_delay}, data),
    do: retry(@t2, data)

  def proceeding(:cast, {:incoming_response, response}, data) do
    receive_response(response)
    case StatusLine.status_code_class(response.start_line) do
      1 -> :keep_state_and_data
      _ -> {:next_state, :completed, data}
    end
  end

  def proceeding(:cast, {:error, reason}, data),
    do: shutdown(reason, data)

  def proceeding(event_type, event_content, data),
    do: handle_event(event_type, event_content, data)

  def completed(:enter, _old_state, %{request: request} = data) do
    data = cancel_timers(data)

    if Transport.Registry.reliable(request) do
      {:stop, :normal, data}
    else
      {:keep_state_and_data, [{:state_timeout, @timer_k, nil}]}
    end
  end

  def completed(:state_timeout, _nil, data),
    do: {:stop, :normal, data}

  def completed(:cast, {:incoming_response, _response}, _data),
    do: :keep_state_and_data

  def completed(:cast, {:error, _reason}, data),
    do: {:stop, :shutdown, data}

  def completed(event_type, event_content, data),
    do: handle_event(event_type, event_content, data)

  def handle_event(event_type, event_content, data),
    do: unhandled_event(event_type, event_content, data)
end
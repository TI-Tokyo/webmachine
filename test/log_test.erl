%% A batch of tests to verify the messages that log handlers receive
%% in various request outcomes.
%%
%% Particular attention is paid to 500 responses including error
%% details.
-module(log_test).
-include("webmachine_logger.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-export([
         init/1,
         service_available/2,
         resource_exists/2,
         content_types_provided/2,
         provide_text/2
        ]).

%%% TESTS

error_log_tests() ->
    [
     fun simple_success/1,
     fun not_found/1,
     fun invalid_callback_result/1,
     fun case_clause_error/1,
     fun halt_500/1,
     fun both_500_and_stream_error/1
    ].

%% 200 OK should get an access log.
simple_success(Ctx) ->
    {{ok, Response}, Logs} = request(Ctx, "", #{log_access => 1}),
    ?assertMatch({{"HTTP/1.1", 200, "OK"}, _, _}, Response),
    AccessLog = lists:keyfind(log_access, 1, Logs),
    ?assertMatch({log_access, #wm_log_data{}}, AccessLog),
    {log_access, #wm_log_data{response_code=Code}} = AccessLog,
    ?assertEqual(200, webmachine_status_code:status_code(Code)),
    assert_no_error_logs(Logs).

%% 404 is also just an access log. It does have an error note
%% attached, but it's just {error, ""}, to send Reason="" to the error
%% handler for response message rendering.
not_found(Ctx) ->
    {{ok, Response}, Logs} = request(Ctx,
                                     "?exists=false",
                                     #{log_access => 1}),
    ?assertMatch({{"HTTP/1.1", 404, "Object Not Found"}, _, _},
                 Response),
    AccessLog = lists:keyfind(log_access, 1, Logs),
    ?assertMatch({log_access, #wm_log_data{}}, AccessLog),
    {log_access, #wm_log_data{response_code=Code}} = AccessLog,
    ?assertEqual(404, webmachine_status_code:status_code(Code)).

%% content_types_provided is expect to return a list of
%% 2-tuples. Decision core catches an internal error if it doesn't.
invalid_callback_result(Ctx) ->
    {{ok, Response}, Logs} = request(Ctx,
                                     "?types=nonlist",
                                     #{log_access => 1}),
    ?assertMatch({{"HTTP/1.1", 500, "Internal Server Error"}, _, _},
                 Response),
    {log_access, #wm_log_data{response_code=Code, notes=Notes}}
        = lists:keyfind(log_access, 1, Logs),
    ?assertEqual(500, webmachine_status_code:status_code(Code)),
    ?assertEqual(true, lists:keymember(error, 1, Notes)).


%% An error in resource code.
case_clause_error(Ctx) ->
    {{ok, Response}, Logs} = request(Ctx,
                                     "?available=breakme",
                                     #{log_access => 1}),
    ?assertMatch({{"HTTP/1.1", 500, "Internal Server Error"}, _, _},
                 Response),
    {log_access, #wm_log_data{response_code=Code, notes=Notes}}
        = lists:keyfind(log_access, 1, Logs),
    ?assertEqual(500, webmachine_status_code:status_code(Code)),
    ?assertMatch({error, {error, {case_clause, "breakme"}, _}},
                 lists:keyfind(error, 1, Notes)).

%% Resource code uses {halt, 500}
halt_500(Ctx) ->
    {{ok, Response}, Logs} = request(Ctx,
                                     "?available=halt",
                                     #{log_access => 1}),
    ?assertMatch({{"HTTP/1.1", 500, _}, _, _}, Response),
    {log_access, #wm_log_data{response_code=Code, notes=Notes}}
        = lists:keyfind(log_access, 1, Logs),
    ?assertEqual(500, webmachine_status_code:status_code(Code)),
    %% halting 4xx,5xx current sets the reason to an empty string
    ?assertEqual({error, ""},
                 lists:keyfind(error, 1, Notes)).

%% Force both a 5xx and a stream error to see that both notes are included.
both_500_and_stream_error(Ctx) ->
    {Response, Logs} = request(Ctx,
                               "?available=streamhalt",
                               #{log_access => 1}),
    ?assertEqual({error, socket_closed_remotely}, Response),
    {log_access, #wm_log_data{response_code=Code, notes=Notes}} =
        lists:keyfind(log_access, 1, Logs),
    ?assertEqual(503, webmachine_status_code:status_code(Code)),
    ErrorNotes = [ N || N={error, _} <- Notes ],
    ?assertEqual(2, length(ErrorNotes)),
    %% the 'false' from service available is the error reason for 503
    ?assertMatch([{error, false}, {error, {stream_error, _}}],
                 lists:sort(ErrorNotes)).

%% SUPPORT / UTIL

request(Ctx, URLAddition, LogCounts) ->
    WaitRef = test_log_handler:clear_logs(),
    Response =
        httpc:request(wm_integration_test_util:url(Ctx)++URLAddition),
    Logs = test_log_handler:wait_for_logs(WaitRef, LogCounts),
    {Response, Logs}.

assert_no_error_logs(Logs) ->
    ?assertEqual(
       [], lists:filter(fun({log_access, #wm_log_data{notes=Notes}}) ->
                                %% this is the new mode of error
                                %% logging, and is a strong assertion
                                lists:keymember(error, 1, Notes);
                           ({log_info, _}) ->
                                false;
                           ({log_error, _}) ->
                                %% this is the old mode of error
                                %% logging, and is a weak assertion
                                %% because of timing dependent
                                true
                        end,
                        Logs)).

%%% REQUEST MODULE

init([]) ->
    {ok, undefined}.

service_available(RD, Ctx) ->
    case wrq:get_qs_value("available", RD) of
        "halt" ->
            {{halt, 500}, RD, Ctx};
        "streamhalt" ->
            Stream = {stream, {<<"a">>, fun() -> throw(double_break) end}},
            RD2 = wrq:set_resp_body(Stream, RD),
            {false, RD2, Ctx};
        undefined ->
            {true, RD, Ctx}
    end.

resource_exists(RD, Ctx) ->
    {wrq:get_qs_value("exists", RD) =/= "false", RD, Ctx}.

%% Using content type to pick the kind of stream the resource will use.
content_types_provided(RD, Ctx) ->
    case wrq:get_qs_value("types", RD) of
        "nonlist" ->
            {nonlist_will_break, RD, Ctx};
        _ ->
            {[{"text/plain", provide_text}],RD, Ctx}
    end.

provide_text(RD, Ctx) ->
    {"here is your text", RD, Ctx}.

%%% TEST SETUP

error_log_test_() ->
    {foreach,
     %% Setup
     fun() ->
             DL = [{[atom_to_list(?MODULE), '*'], ?MODULE, []}],
             Ctx = wm_integration_test_util:start(?MODULE, "0.0.0.0", DL),
             webmachine_log:add_handler(test_log_handler, []),
             Ctx
     end,
     %% Cleanup
     fun(Ctx) ->
             wm_integration_test_util:stop(Ctx)
     end,
     %% Test functions provided with context from setup
     [fun(Ctx) ->
              {spawn, {with, Ctx, error_log_tests()}}
      end]}.

-endif.

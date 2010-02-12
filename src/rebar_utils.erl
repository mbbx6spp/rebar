%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009, 2010 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_utils).

-export([get_cwd/0,
         is_arch/1,
         get_arch/0,
         get_os/0,
         sh/2, sh/3,
         sh_failfast/2,
         find_files/2,
         now_str/0,
         ensure_dir/1,
         beam_to_mod/2, beams/1]).

-include("rebar.hrl").

%% ====================================================================
%% Public API
%% ====================================================================

get_cwd() ->
    {ok, Dir} = file:get_cwd(),
    Dir.


is_arch(ArchRegex) ->
    case re:run(get_arch(), ArchRegex, [{capture, none}]) of
        match ->
            true;
        nomatch ->
            false
    end.

get_arch() ->
    Words = integer_to_list(8 * erlang:system_info(wordsize)),
    erlang:system_info(system_architecture) ++ "-" ++ Words.

get_os() ->
    Arch = erlang:system_info(system_architecture),
    case match_first([{"linux", linux}, {"darwin", darwin}], Arch) of
        nomatch ->
            {unknown, Arch};
        ArchAtom ->
            ArchAtom
    end.


sh(Command, Env) ->
    sh(Command, Env, get_cwd()).

sh(Command, Env, Dir) ->
    ?INFO("sh: ~s\n~p\n", [Command, Env]),
    Port = open_port({spawn, Command}, [{cd, Dir}, {env, Env}, exit_status, {line, 16384},
                                        use_stdio, stderr_to_stdout]),
    case sh_loop(Port) of
        ok ->
            ok;
        {error, Rc} ->
            ?ABORT("~s failed with error: ~w\n", [Command, Rc])
    end.

sh_failfast(Command, Env) ->
    sh(Command, Env).

find_files(Dir, Regex) ->
    filelib:fold_files(Dir, Regex, true, fun(F, Acc) -> [F | Acc] end, []).

now_str() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:local_time(),
    lists:flatten(io_lib:format("~4b/~2..0b/~2..0b ~2..0b:~2..0b:~2..0b", 
				[Year, Month, Day, Hour, Minute, Second])).

%% TODO: Review why filelib:ensure_dir/1 sometimes returns {error, eexist}.
%% There appears to be a race condition when calling ensure_dir from
%% multiple processes simultaneously.
%% This does not happen with -j1 but with anything higher than that.
%% So -j2 or default jobs setting will reveal the issue.
%% To reproduce make sure that the priv/mibs directory does not exist
%% $ rm -r priv
%% $ ./rebar -v compile
ensure_dir(Path) ->
    case filelib:ensure_dir(Path) of
        ok ->
            ok;
        {error,eexist} ->
            ok;
        Error ->
            Error
    end.

%% ====================================================================
%% Internal functions
%% ====================================================================

match_first([], _Val) ->
    nomatch;
match_first([{Regex, MatchValue} | Rest], Val) ->
    case re:run(Val, Regex, [{capture, none}]) of
        match ->
            MatchValue;
        nomatch ->
           match_first(Rest, Val)
    end.

sh_loop(Port) ->
    receive
        {Port, {data, {_, Line}}} ->
            ?CONSOLE("~s\n", [Line]),
            sh_loop(Port);
        {Port, {exit_status, 0}} ->
            ok;
        {Port, {exit_status, Rc}} ->
            {error, Rc}
    end.

beam_to_mod(Dir, Filename) ->
    [Dir | Rest] = filename:split(Filename),
    list_to_atom(filename:basename(string:join(Rest, "."), ".beam")).

beams(Dir) ->
    filelib:fold_files(Dir, ".*\.beam\$", true,
                       fun(F, Acc) -> [F | Acc] end, []).


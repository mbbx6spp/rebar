%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
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
-module(rebar_templater).

-export(['create-app'/2,
         'create-node'/2,
         'list-templates'/2,
         create/2]).

-include("rebar.hrl").

-define(TEMPLATE_RE, ".*\\.template\$").

%% ===================================================================
%% Public API
%% ===================================================================

'create-app'(Config, File) ->
    %% Alias for create w/ template=simpleapp
    rebar_config:set_global(template, "simpleapp"),
    create(Config, File).

'create-node'(Config, File) ->
    %% Alias for create w/ template=simplenode
    rebar_config:set_global(template, "simplenode"),
    create(Config, File).

'list-templates'(_Config, _File) ->
    %% Load a list of all the files in the escript -- cache it in the pdict
    %% since we'll potentially need to walk it several times over the course
    %% of a run.
    cache_escript_files(),

    %% Build a list of available templates
    AvailTemplates = find_disk_templates() ++ find_escript_templates(),
    ?CONSOLE("Available templates:\n", []),
    [?CONSOLE("\t* ~s: ~s (~p)\n", [filename:basename(F, ".template"), F, Type]) ||
        {Type, F} <- AvailTemplates],
    ok.


create(_Config, _) ->
    %% Load a list of all the files in the escript -- cache it in the pdict
    %% since we'll potentially need to walk it several times over the course
    %% of a run.
    cache_escript_files(),

    %% Build a list of available templates
    AvailTemplates = find_disk_templates() ++ find_escript_templates(),
    ?DEBUG("Available templates: ~p\n", [AvailTemplates]),

    %% Using the specified template id, find the matching template file/type.
    %% Note that if you define the same template in both ~/.rebar/templates
    %% that is also present in the escript, the one on the file system will
    %% be preferred.
    {Type, Template} = select_template(AvailTemplates, template_id()),

    %% Load the template definition as is and get the list of variables the
    %% template requires.
    TemplateTerms = consult(load_file(Type, Template)),
    case lists:keysearch(variables, 1, TemplateTerms) of
        {value, {variables, Vars}} ->
            case parse_vars(Vars, dict:new()) of
                {error, Entry} ->
                    Context0 = undefined,
                    ?ABORT("Failed while processing variables from template ~p."
                           "Variable definitions must follow form of "
                           "[{atom(), term()}]. Failed at: ~p\n",
                           [template_id(), Entry]);
                Context0 ->
                    ok
            end;
        false ->
            ?WARN("No variables section found in template ~p; using empty context.\n",
                  [template_id()]),
            Context0 = dict:new()
    end,

    %% For each variable, see if it's defined in global vars -- if it is, prefer that
    %% value over the defaults
    Context = update_vars(dict:fetch_keys(Context0), Context0),
    ?DEBUG("Template ~p context: ~p\n", [template_id(), dict:to_list(Context)]),

    %% Now, use our context to process the template definition -- this permits us to
    %% use variables within the definition for filenames.
    FinalTemplate = consult(render(load_file(Type, Template), Context)),
    ?DEBUG("Final template def ~p: ~p\n", [template_id(), FinalTemplate]),

    %% Execute the instructions in the finalized template
    Force = rebar_config:get_global(force, "0"),
    execute_template(FinalTemplate, Type, Template, Context, Force, []).




%% ===================================================================
%% Internal functions
%% ===================================================================

%%
%% Scan the current escript for available files and cache in pdict.
%%
cache_escript_files() ->
    {ok, Files} = rebar_utils:escript_foldl(
                      fun(Name, _, GetBin, Acc) ->
                              [{Name, GetBin()} | Acc]
                      end,
                      [], rebar_config:get_global(escript, undefined)),
    erlang:put(escript_files, Files).


template_id() ->
    case rebar_config:get_global(template, undefined) of
        undefined ->
            ?ABORT("No template specified.\n", []);
        TemplateId ->
            TemplateId
    end.

find_escript_templates() ->
    [{escript, Name} || {Name, _Bin} <- erlang:get(escript_files),
                        re:run(Name, ?TEMPLATE_RE, [{capture, none}]) == match].

find_disk_templates() ->
    HomeFiles = rebar_utils:find_files(filename:join(os:getenv("HOME"),
                                                     ".rebar/templates"), ?TEMPLATE_RE),
    LocalFiles = rebar_utils:find_files(".", ?TEMPLATE_RE),
    [{file, F} || F <- HomeFiles++LocalFiles].

select_template([], Template) ->
    ?ABORT("Template ~s not found.\n", [Template]);
select_template([{Type, Avail} | Rest], Template) ->
    case filename:basename(Avail, ".template") == Template of
        true ->
            {Type, Avail};
        false ->
            select_template(Rest, Template)
    end.

%%
%% Read the contents of a file from the appropriate source
%%
load_file(escript, Name) ->
    {Name, Bin} = lists:keyfind(Name, 1, erlang:get(escript_files)),
    Bin;
load_file(file, Name) ->
    {ok, Bin} = file:read_file(Name),
    Bin.

%%
%% Parse/validate variables out from the template definition
%%
parse_vars([], Dict) ->
    Dict;
parse_vars([{Key, Value} | Rest], Dict) when is_atom(Key) ->
    parse_vars(Rest, dict:store(Key, Value, Dict));
parse_vars([Other | _Rest], _Dict) ->
    {error, Other};
parse_vars(Other, _Dict) ->
    {error, Other}.

%%
%% Given a list of keys in Dict, see if there is a corresponding value defined
%% in the global config; if there is, update the key in Dict with it
%%
update_vars([], Dict) ->
    Dict;
update_vars([Key | Rest], Dict) ->
    Value = rebar_config:get_global(Key, dict:fetch(Key, Dict)),
    update_vars(Rest, dict:store(Key, Value, Dict)).


%%
%% Given a string or binary, parse it into a list of terms, ala file:consult/0
%%
consult(Str) when is_list(Str) ->
    consult([], Str, []);
consult(Bin) when is_binary(Bin)->
    consult([], binary_to_list(Bin), []).

consult(Cont, Str, Acc) ->
    case erl_scan:tokens(Cont, Str, 0) of
        {done, Result, Remaining} ->
            case Result of
                {ok, Tokens, _} ->
                    {ok, Term} = erl_parse:parse_term(Tokens),
                    consult([], Remaining, [Term | Acc]);
                {eof, _Other} ->
                    lists:reverse(Acc);
                {error, Info, _} ->
                    {error, Info}
            end;
        {more, Cont1} ->
            consult(Cont1, eof, Acc)
    end.


%%
%% Render a binary to a string, using mustache and the specified context
%%
render(Bin, Context) ->
    %% Be sure to escape any double-quotes before rendering...
    Str = re:replace(Bin, "\"", "\\\\\"", [global, {return,list}]),
    mustache:render(Str, Context).

write_file(Output, Data, Force) ->
    %% determine if the target file already exists
    FileExists = filelib:is_file(Output),

    %% perform the function if we're allowed,
    %% otherwise just process the next template
    if
        Force =:= "1"; FileExists =:= false ->
            filelib:ensure_dir(Output),
            if
                {Force, FileExists} =:= {"1", true} ->
                    ?CONSOLE("Writing ~s (forcibly overwriting)~n",
                             [Output]);
                true ->
                    ?CONSOLE("Writing ~s~n", [Output])
            end,
            case file:write_file(Output, Data) of
                ok ->
                    ok;
                {error, Reason} ->
                    ?ABORT("Failed to write output file ~p: ~p\n",
                           [Output, Reason])
            end;
        true ->
            {error, exists}
    end.


%%
%% Execute each instruction in a template definition file.
%%
execute_template([], _TemplateType, _TemplateName, _Context, _Force, ExistingFiles) ->
    case length(ExistingFiles) of
        0 ->
            ok;
        _ ->
            Msg = lists:flatten([io_lib:format("\t* ~p~n", [F]) || F <- lists:reverse(ExistingFiles)]),
            Help = "To force overwriting, specify force=1 on the command line.\n",
            ?ERROR("One or more files already exist on disk and were not generated:~n~s~s", [Msg , Help])
    end;
execute_template([{template, Input, Output} | Rest], TemplateType, TemplateName, Context, Force, ExistingFiles) ->
    InputName = filename:join(filename:dirname(TemplateName), Input),
    case write_file(Output, render(load_file(TemplateType, InputName), Context), Force) of
        ok ->
            execute_template(Rest, TemplateType, TemplateName, Context,
                             Force, ExistingFiles);
        {error, exists} ->
            execute_template(Rest, TemplateType, TemplateName, Context,
                             Force, [Output|ExistingFiles])
    end;
execute_template([{file, Input, Output} | Rest], TemplateType, TemplateName, Context, Force, ExistingFiles) ->
    InputName = filename:join(filename:dirname(TemplateName), Input),
    case write_file(Output, load_file(TemplateType, InputName), Force) of
        ok ->
            execute_template(Rest, TemplateType, TemplateName, Context,
                             Force, ExistingFiles);
        {error, exists} ->
            execute_template(Rest, TemplateType, TemplateName, Context,
                             Force, [Output|ExistingFiles])
    end;
execute_template([{dir, Name} | Rest], TemplateType, TemplateName, Context, Force, ExistingFiles) ->
    case filelib:ensure_dir(filename:join(Name, "dummy")) of
        ok ->
            execute_template(Rest, TemplateType, TemplateName, Context, Force, ExistingFiles);
        {error, Reason} ->
            ?ABORT("Failed while processing template instruction {dir, ~s}: ~p\n",
                   [Name, Reason])
    end;
execute_template([{chmod, Mod, File} | Rest], TemplateType, TemplateName, Context, Force, ExistingFiles) when is_integer(Mod) ->
    case file:change_mode(File, Mod) of
        ok ->
            execute_template(Rest, TemplateType, TemplateName, Context, Force, ExistingFiles);
        {error, Reason} ->
            ?ABORT("Failed while processing template instruction {cmod, ~b, ~s}: ~p~n",
                   [Mod, File, Reason])
    end;
execute_template([{variables, _} | Rest], TemplateType, TemplateName, Context, Force, ExistingFiles) ->
    execute_template(Rest, TemplateType, TemplateName, Context, Force, ExistingFiles);
execute_template([Other | Rest], TemplateType, TemplateName, Context, Force, ExistingFiles) ->
    ?WARN("Skipping unknown template instruction: ~p\n", [Other]),
    execute_template(Rest, TemplateType, TemplateName, Context, Force, ExistingFiles).


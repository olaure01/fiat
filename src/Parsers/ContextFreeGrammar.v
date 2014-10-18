(** * Definition of Context Free Grammars *)
Require Import Coq.Strings.String Coq.Lists.List Coq.Program.Program.
Require Export Parsers.StringLike.

Set Implicit Arguments.

Module ContextFreeGrammar (S : StringLike).
  Import S.

  Section definitions.
    (** An [item] is the basic building block of a context-free
        grammar; it is either a terminal ([CharType]-literal) or a
        nonterminal of a given name. *)
    Inductive item :=
    | Terminal (_ : CharType)
    | NonTerminal (name : string).

    (** A [productions] is a list of possible [production]s; a
        [production] is a list of [item]s.  A string matches a
        [production] if it can be broken up into components that match
        the relevant element of the [production]. *)
    Definition production := list item.
    Definition productions := list production.

    Definition productions_dec (CharType_eq_dec : forall x y : CharType, {x = y} + {x <> y})
               (x y : productions) : {x = y} + {x <> y}.
    Proof.
      repeat (apply list_eq_dec; intros);
      decide equality.
      apply string_dec.
    Defined.

    (** A [grammar] consists of [productions] to match a string
        against, and a function mapping names to [productions]. *)
    (** TODO(jgross): look up notations for specifying these nicely *)
    Record grammar :=
      {
        Start_symbol :> string;
        Lookup :> string -> productions;
        Start_production :> productions := Lookup Start_symbol;
        Valid_nonterminal_symbols : list string;
        Valid_nonterminals : list productions := map Lookup Valid_nonterminal_symbols
      }.
  End definitions.

  Section parse.
    Variable G : grammar.
    (** A parse of a string into [productions] is a [production] in
        that list, together with a list of substrings which cover the
        original string, each of which is a parse of the relevant
        component of the [production]. *)
    Inductive parse_of : t -> productions -> Type :=
    | ParseHead : forall str pat pats, parse_of_production str pat
                                       -> parse_of str (pat::pats)
    | ParseTail : forall str pat pats, parse_of str pats
                                       -> parse_of str (pat::pats)
    with parse_of_production : t -> production -> Type :=
    | ParseProductionNil : parse_of_production Empty nil
    | ParseProductionCons : forall str pat strs pats,
                           parse_of_item str pat
                           -> parse_of_production strs pats
                           -> parse_of_production (str ++ strs) (pat::pats)
    with parse_of_item : t -> item -> Type :=
    | ParseTerminal : forall x, parse_of_item [[ x ]]%string_like (Terminal x)
    | ParseNonTerminal : forall name str, parse_of str (Lookup G name)
                                          -> parse_of_item str (NonTerminal name).

    Definition ParseProductionSingleton str it (p : parse_of_item str it) : parse_of_production str [ it ].
    Proof.
      rewrite <- (RightId str).
      constructor; assumption || constructor.
    Defined.

    Definition ParseProductionApp str1 str2 p1 p2
               (pop1 : parse_of_production str1 p1) (pop2 : parse_of_production str2 p2)
    : parse_of_production (str1 ++ str2) (p1 ++ p2)%list.
    Proof.
      induction pop1; simpl.
      { rewrite LeftId; assumption. }
      { rewrite Associativity.
        constructor; assumption. }
    Defined.

    Definition ParseApp str1 str2 p1 p2 (po1 : parse_of str1 [ p1 ]) (po2 : parse_of str2 [ p2 ])
    : parse_of (str1 ++ str2) [ (p1 ++ p2)%list ].
    Proof.
      inversion_clear po1; inversion_clear po2;
      try match goal with
            | [ H : parse_of _ [] |- _ ] => exfalso; revert H; clear; intro H; abstract inversion H
          end.
      { constructor. apply ParseProductionApp; assumption. }
    Defined.
  End parse.

  Definition parse_of_grammar (str : t) (G : grammar) :=
    parse_of G str G.

  Section generic.
    Definition trivial_grammar : grammar :=
      {| Start_symbol := "";
         Lookup := fun _ => nil::nil;
         Valid_nonterminal_symbols := ""%string::nil |}.

    Definition trivial_grammar_parses_empty_string : parse_of_grammar S.Empty trivial_grammar.
    Proof.
      hnf.
      simpl.
      apply ParseHead.
      constructor.
    Qed.
  End generic.
End ContextFreeGrammar.

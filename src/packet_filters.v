Require Import Fiat.Narcissus.Examples.NetworkStack.IPv4Header.
Require Import Fiat.Narcissus.Examples.NetworkStack.TCP_Packet.
Require Import Bedrock.Word.
Require Import Coq.Arith.Arith.
Require Import Coq.Lists.List.
Import ListNotations.
Require Import Fiat.QueryStructure.Automation.MasterPlan.
Require Import IndexedEnsembles.
Require Import Fiat.Narcissus.Examples.Guard.IPTables.
Require Import Fiat.Narcissus.Examples.Guard.PacketFiltersLemmas.

Definition sINPUT := "Input".
Definition sHISTORY := "GlobalHistory".
Definition PacketHistorySchema :=
  Query Structure Schema
        [ relation sHISTORY has
                   schema < sINPUT :: input > ]
        enforcing [].
Definition myqidx:
  Fin.t (numRawQSschemaSchemas PacketHistorySchema).
  cbn. apply Fin.F1. Defined.

Definition StatefulFilterSig : ADTSig :=
  ADTsignature {
      Constructor "Init" : rep,
      Method "Filter" : rep * input -> rep * (option result)
    }.


(**
we are 18.X.X.X
outside world is all other IP addresses
filter allows outside address to talk to us only if we have talked to it first
**)

Definition OutgoingRule :=
  iptables -A FORWARD --source 18'0'0'0/24.

Definition IncomingRule :=
  iptables -A FORWARD --destination 18'0'0'0/24.

Definition OutgoingToRule (dst: address) :=
  and_cf OutgoingRule (lift_condition in_ip4 (cond_dstaddr {| saddr := dst; smask := mask_of_nat 32 |})).

Lemma OutgoingToImpliesOutgoing:
  forall inp dst,
    (OutgoingToRule dst).(cf_cond) inp -> OutgoingRule.(cf_cond) inp.
Proof.
  intros. simpl in *. unfold combine_conditions in *. apply andb_prop in H. destruct H. rewrite H. constructor. Qed.

Opaque OutgoingRule.
Opaque IncomingRule.
Opaque OutgoingToRule.

Definition FilterMethod (r: QueryStructure PacketHistorySchema) (inp: input) : Comp (option result) :=
  if (OutgoingRule.(cf_cond) inp) then ret (Some ACCEPT)
  else if negb (IncomingRule.(cf_cond) inp) then ret None
  else b <- { b: bool | decides b (exists pre,
    IndexedEnsemble_In (GetRelation r Fin.F1) < sINPUT :: pre > /\
    ((OutgoingToRule inp.(in_ip4).(SourceAddress)).(cf_cond) pre = true)) };
    if b then ret (Some ACCEPT) else ret (Some DROP).

Definition FilterMethod_UnConstr (r: UnConstrQueryStructure PacketHistorySchema) (inp: input) : Comp (option result) :=
  if (OutgoingRule.(cf_cond) inp) then ret (Some ACCEPT)
  else if negb (IncomingRule.(cf_cond) inp) then ret None
  else b <- { b: bool | decides b (exists pre,
    IndexedEnsemble_In (GetUnConstrRelation r Fin.F1) < sINPUT :: pre > /\
    ((OutgoingToRule inp.(in_ip4).(SourceAddress)).(cf_cond) pre = true)) };
    if b then ret (Some ACCEPT) else ret (Some DROP).

Lemma UnConstrPreservesFilterMethod: forall r_o r_n inp res,
  DropQSConstraints_AbsR r_o r_n ->
  computes_to (FilterMethod r_o inp) res <->
  computes_to (FilterMethod_UnConstr r_n inp) res.
Proof.
  intros. unfold FilterMethod, FilterMethod_UnConstr in *.
  destruct (OutgoingRule.(cf_cond) inp) eqn:out. reflexivity.
  destruct (negb (IncomingRule.(cf_cond) inp)) eqn:inc. reflexivity.
  split; intros; apply Bind_inv in H0; destruct H0 as [b [Hbin Hbres]];
    unfold DropQSConstraints_AbsR in H; rewrite <- H in *; computes_to_econstructor;
    [rewrite GetRelDropConstraints; apply Hbin | apply Hbres
    | rewrite <- GetRelDropConstraints; apply Hbin | apply Hbres].
Qed.


Definition NoIncomingConnectionsFilter : ADT StatefulFilterSig :=
  Eval simpl in Def ADT {
    rep := QueryStructure PacketHistorySchema,
    Def Constructor0 "Init" : rep := empty,,

    Def Method1 "Filter" (r: rep) (inp: input) : rep * option result :=
      res <- FilterMethod r inp;
      `(r, _) <- Insert (< sINPUT :: inp >) into r!sHISTORY;
      ret (r, res)
  }%methDefParsing.

Lemma simpl_in_bind:
  forall (T U: Type) (x v : T) (y: U),
    In T (`(r', _) <- ret (x, y); ret r') v -> x = v.
Proof.
  intros. apply Bind_inv in H. destruct H. destruct H. apply Return_inv in H. rewrite <- H in H0. simpl in H0. apply Return_inv in H0. assumption. Qed.

Print FiniteTables_AbsR.
Definition LessHistoryRelation (r_o r_n : UnConstrQueryStructure PacketHistorySchema) :=
  FiniteTables_AbsR r_o r_o /\
  forall inp,
    (OutgoingRule.(cf_cond) inp) ->
    ((IndexedEnsemble_In (GetUnConstrRelation r_n Fin.F1) < sINPUT :: inp >)
     <-> IndexedEnsemble_In (GetUnConstrRelation r_o Fin.F1) < sINPUT :: inp >).

Lemma LessHistoryPreservesFilter:
  forall inp r_o r_n,
    LessHistoryRelation r_o r_n ->
    refine
      (FilterMethod_UnConstr r_o inp)
      (FilterMethod_UnConstr r_n inp).
Proof.
  red; intros. unfold FilterMethod_UnConstr in *.
  unfold LessHistoryRelation in H. destruct H as [Hfin H].
  destruct (cf_cond OutgoingRule inp) eqn:outrule;
    destruct (negb (cf_cond IncomingRule inp)) eqn:ninrule;
    simpl in *; try apply H0.
  inversion H0. destruct H1. computes_to_econstructor.
  destruct x eqn:truefalse.

  - instantiate (1 := x).
    computes_to_econstructor. unfold decides; simpl.
    destruct H1. destruct H1. exists x0. split.
    * apply (H x0).
      apply (OutgoingToImpliesOutgoing x0 (SourceAddress (in_ip4 inp))).
      assumption. assumption.
    * assumption.

  - computes_to_econstructor; unfold decides; simpl.
    unfold not; intros. destruct H1. destruct H3. destruct H1.
    exists x0. split.
    * apply (H x0).
      apply (OutgoingToImpliesOutgoing x0 (SourceAddress (in_ip4 inp))).
      assumption. assumption.
    * assumption.

  - assumption.
Qed.


Definition UnConstrQuery_In {ResultT}
           {qsSchema}
           (qs : UnConstrQueryStructure qsSchema)
           (R : Fin.t _)
           (bod : RawTuple -> Comp (list ResultT))
  := QueryResultComp (GetUnConstrRelation qs R) bod.

Notation "( x 'in' r '%' Ridx ) bod" :=
  (let qs_schema : QueryStructureSchema := _ in
   let r' : UnConstrQueryStructure qs_schema := r in
   let Ridx' := ibound (indexb (@Build_BoundedIndex _ _ (QSschemaNames qs_schema) Ridx%string _)) in
   @UnConstrQuery_In _ qs_schema r' Ridx'
            (fun x : @RawTuple (GetNRelSchemaHeading (qschemaSchemas qs_schema) Ridx') => bod)) (at level 0, x at level 200, r at level 0, bod at level 0).

Definition FilterMethod_UnConstr_Comp (r: UnConstrQueryStructure PacketHistorySchema) (inp: input) : Comp (option result) :=
  If cf_cond OutgoingRule inp Then ret (Some ACCEPT) Else
  If negb (cf_cond IncomingRule inp) Then ret None Else
    (c <- Count (For (t in r%sHISTORY)
                 Where (cf_cond (OutgoingToRule (SourceAddress (in_ip4 inp))) (t!sINPUT) = true)
                 Return ());
     If 0 <? c Then ret (Some ACCEPT) Else ret (Some DROP)).


Lemma permutation_length {A: Type}:
  forall (l1 l2 : list A),
    Permutation l1 l2 -> Datatypes.length l1 = Datatypes.length l2.
Proof.
  intros. induction H; simpl; congruence.
Qed.

Lemma fold_comp_list_in:
  forall (T: Type) (P: T -> bool) (ltup: list T) l inp,
    fold_right
      (fun b a : Comp (list ()) =>
         l <- b;
         l' <- a;
         ret (l ++ l')%list) (ret [])
      (map
         (fun t : T =>
            {l : list () |
             (P t -> ret [()] ↝ l) /\ (~ P t -> l = [])}) ltup) l ->
    List.In inp ltup ->
    P inp ->
    0 <? Datatypes.length l.
Proof.
  intros T P. induction ltup.
  - intros; auto.
  - intros l inp Hf Hin Hp. cbn in Hf.  destruct Hf as [x [Hx [y [Hy Happ]]]].
    unfold In in *. inversion Happ. destruct Hin as [Hin | Hin].
    * subst inp. inversion Hx. apply H0 in Hp. inversion Hp. auto.
    * pose proof (IHltup y inp Hy Hin Hp) as Hind. rewrite app_length.
      apply Nat.ltb_lt; apply Nat.lt_lt_add_l; apply Nat.ltb_lt; assumption.
Qed.

Lemma fold_comp_list_length:
  forall l l',
    fold_right
      (fun b a : Comp (list ()) =>
         l <- b;
         l' <- a;
         ret (l ++ l')%list) (ret [])
      l' l ->
    0 <? Datatypes.length l ->
    exists lin, List.In lin l' /\
                (exists lin', lin lin' /\ 0 <? Datatypes.length lin').
Proof.
  intros l l'. generalize dependent l. induction l'.
  - simpl. intros. inversion H. subst l. inversion H0.
  - simpl. intros. destruct H as [l1 [Hl1 Hl]]. red in Hl1. red in Hl.
    destruct Hl as [l2 [Hl2 Hl]]. red in Hl2. red in Hl. inversion Hl.
    destruct (0 <? Datatypes.length l2) eqn:Hlen2.
    * pose proof (IHl' l2 Hl2 Hlen2) as IH.
      destruct IH as [lin [Hlin1 Hlin2]]. exists lin. split.
      right; assumption. assumption.
    * apply Nat.ltb_ge in Hlen2. inversion Hlen2. rewrite <- H in H0.
      rewrite app_length in H0. rewrite H2 in H0. rewrite Nat.add_0_r in H0.
      exists a. split.
      left; reflexivity. exists l1. split. assumption. rewrite H2. apply H0.
Qed.

Lemma count_zero_iff:
  forall (r: UnConstrQueryStructure PacketHistorySchema)
         (P: @RawTuple _ -> bool) count,
    computes_to (Count (For (UnConstrQuery_In r myqidx
                        (fun t =>
                          Where (P t)
                          Return ())))) count ->
    ((0 <? count) <-> (exists inp, IndexedEnsemble_In (GetUnConstrRelation r myqidx) < sINPUT :: inp > /\ P < sINPUT :: inp >)).
Proof.
  Transparent Query_For. Transparent Count. Transparent QueryResultComp.
  unfold Count, Query_For, Query_Where, Query_Return, UnConstrQuery_In.
  unfold QueryResultComp, FlattenCompList.flatten_CompList.
  intros r P count Hcount. destruct Hcount as [l [Hcount Htmp]].
  unfold In in *. inversion Htmp. rename H into Hlen. clear Htmp.
  destruct Hcount as [l' [Htmp Hperm]]. apply Pick_inv in Hperm.
  unfold In in *. destruct Htmp as [ltup [Hrel Hfold]].
  apply Pick_inv in Hrel. unfold In in *.
  pose proof (permutation_length l' l Hperm) as Hpermlen.
  rewrite <- Hpermlen in *. clear Hperm. clear Hpermlen. clear l.
  split; intros H.
  - pose proof (fold_comp_list_length l' _ Hfold H) as Hlin0.
    destruct Hlin0 as [lin [Hlinm [lin' [Hll Hlinc]]]].
    apply in_map_iff in Hlinm. destruct Hlinm as [x [Hpx Hlx]].
    cbv in (type of x).
    assert (Htuple: < sINPUT :: (prim_fst x) > = x).
    { destruct x. cbv. destruct prim_snd. reflexivity. }
    exists (prim_fst x). split.
    * red in Hrel. destruct Hrel as [l [Hmap [Heql Hdup]]].
      rewrite Htuple. red. rewrite <- Hmap in Hlx.
      apply in_map_iff in Hlx.
      destruct Hlx as [y [Hy1 Hy2]]. destruct y as [yidx yelem].
      exists yidx. simpl in Hy1. subst x. apply Heql. apply Hy2.
    * rewrite Htuple. subst lin. inversion Hll.
      destruct (P x) eqn:Hpx. reflexivity.
      assert (Hle: lin' = []) by (apply H1; congruence). subst lin'.
      inversion Hlinc.

  - red in Hrel. destruct Hrel as [l [Hmap [Heql Hdup]]].
    destruct H as [inp [Hinp Hpinp]]. red in Hinp. destruct Hinp as [idx Hinp].
    apply Heql in Hinp.
    assert (Hinp': List.In (< sINPUT :: inp >) ltup).
    { rewrite <- Hmap. apply in_map_iff.
      exists {| elementIndex := idx; indexedElement := < sINPUT :: inp > |}.
      split. reflexivity. assumption. }
    apply (fold_comp_list_in _ P ltup l' _ Hfold Hinp' Hpinp).
Qed.    

Lemma CompPreservesFilterMethod:
  forall r inp,
    refine (FilterMethod_UnConstr r inp)
           (FilterMethod_UnConstr_Comp r inp).
Proof.
  unfold FilterMethod_UnConstr, FilterMethod_UnConstr_Comp. red; intros.
  destruct (cf_cond OutgoingRule inp) eqn:outrule. assumption.
  destruct (negb (cf_cond IncomingRule inp)) eqn:inrule. assumption.
  inversion H as [c Hc]. destruct Hc as [Hcount Hres]. unfold In in *.

  pose proof (count_zero_iff _ _ c Hcount) as Hcziff.
  computes_to_econstructor. computes_to_econstructor.
  instantiate (1:=(0 <? c)). red. destruct (0 <? c) eqn:Hzero; simpl.
  - rewrite <- Hzero in Hcziff. apply Hcziff in Hzero.
    destruct Hzero as [pre [Hin Hcond]].
    exists pre. split; assumption.
  - intro. rewrite <- Hzero in Hcziff. apply Hcziff in H0. inversion H0.
    rewrite H2 in Hzero. inversion Hzero.
  - apply Hres.
Qed.


Lemma LessHistoryRelationRefl:
  forall r_o, FiniteTables_AbsR r_o r_o -> LessHistoryRelation r_o r_o.
Proof.
  unfold LessHistoryRelation; split. assumption.
  split; intros; assumption. Qed.


Lemma QSEmptyFinite {qs_schema}:
  forall idx, FiniteEnsemble (GetUnConstrRelation (DropQSConstraints (QSEmptySpec qs_schema)) idx).
Proof.
  intros. red. exists []. red. exists [].
  split.
  - reflexivity.
  - split.
    * split; intros.
      + cbn in H. red in H. red in H.
        change (Vector.map schemaRaw (QSschemaSchemas qs_schema))
          with (qschemaSchemas qs_schema) in H. rewrite <- ith_imap2 in H.
        remember (ith2 _ _) in *.
        change (numQSschemaSchemas qs_schema)
          with (numRawQSschemaSchemas (QueryStructureSchemaRaw qs_schema)) in Heqy.
        change (fun x => ?f x) with f in Heqy.

        rewrite (Build_EmptyRelation_IsEmpty qs_schema idx) in Heqy.
        subst y. cbn in H. inversion H.
      + inversion H.
    * constructor.
Qed.

Definition incrMaxFreshIdx {T: Type} (l: list (@IndexedElement T)) :=
  S (fold_right (fun elem acc => max (elementIndex elem) acc) 0 l).

Print UnIndexedEnsembleListEquivalence. Print FiniteEnsemble.
Lemma incrMaxFreshIdx_computes:
  forall {qs_schema} {qidx: Fin.t (numRawQSschemaSchemas qs_schema)}
         (r: UnConstrQueryStructure qs_schema) l l',
    map indexedElement l' = l /\
    (forall x : IndexedElement,
    In IndexedElement (GetUnConstrRelation r qidx) x <-> List.In x l') /\
    NoDup (map elementIndex l') ->
    computes_to
      {idx: nat | UnConstrFreshIdx (GetUnConstrRelation r qidx) idx}
      (incrMaxFreshIdx l').
Proof.
  intros qsc qidx r l l' [Hmap [Heqv Hdup]]. computes_to_econstructor.
  red; intros elem Helem. apply Heqv in Helem.
  unfold lt. apply le_n_S. apply fold_right_max_is_max. apply Helem. Qed.

Lemma list_helper:
  forall {T: Type} (l: list T) (f: T -> nat) (big: nat),
    lt (fold_right (fun e acc => max (f e) acc) 0 l) big ->
    ~ List.In big (map f l).
Proof.
  induction l.
  - auto.
  - unfold not; intros f big Hbig H. cbn in Hbig. cbn in H.
    pose proof
         (Nat.max_spec (f a)
                       (fold_right (fun (e : T) (acc : nat) =>
                                      Init.Nat.max (f e) acc) 0 l)) as Hmax.
    destruct Hmax as [[Hlt Hmax] | [Hlt Hmax]]; rewrite Hmax in Hbig;
      destruct H as [H | H].
    + subst big. pose proof (lt_trans _ _ _ Hlt Hbig).
      apply lt_irrefl in H. auto.
    + apply (IHl f big Hbig H).
    + subst big. apply lt_irrefl in Hbig. auto.
    + pose proof (le_lt_trans _ _ _ Hlt Hbig). apply (IHl f big H0 H).
Qed.

Definition RefinedInsert r d :=
  If cf_cond OutgoingRule d
  Then
    (idx <- {idx: nat |
             UnConstrFreshIdx (GetUnConstrRelation r myqidx) idx};
     ret (UpdateUnConstrRelation r myqidx
            (BuildADT.EnsembleInsert
               {| elementIndex := idx;
                  indexedElement := icons2 d inil2 |}
               (GetUnConstrRelation r myqidx))))
  Else
    ret r.

Ltac comp_inv :=
  match goal with
  | [H: computes_to _ _ |- _] => inversion H; unfold In in *; clear H
  | [H: _ /\ _ |- _] => destruct H
  | [H: ret _ _ |- _] => inversion H; clear H
  | [H: Bind _ _ _ |- _] => inversion H; unfold In in *; clear H
  end.


Instance ByteBuffer_eq_dec:
  forall n, Query_eq (ByteBuffer.ByteBuffer.t n).
econstructor. revert n. unfold ByteBuffer.ByteBuffer.t.
eapply Vector.rect2.
- auto.
- destruct 1.
  * subst. intros; destruct (A_eq_dec a b).
    + subst. auto.
    + right. intro. inversion H. congruence.
  * right. intro. inversion H.
    apply Eqdep_dec.inj_pair2_eq_dec in H2. congruence. apply A_eq_dec.
Defined.


Instance word_eq_dec:
  forall n, Query_eq (word n).
econstructor. apply weq. Defined.

Instance TCP_Packet_eq_dec:
  Query_eq (TCP_Packet).
econstructor. repeat decide equality; subst; try apply A_eq_dec.
destruct Payload. destruct Payload0. destruct (A_eq_dec x x0).
- subst; destruct (A_eq_dec t t0). subst; auto.
  right; intro. apply Eqdep_dec.inj_pair2_eq_dec in H. congruence.
  apply A_eq_dec.
- right; intro. congruence.
Defined.

Instance UDP_Packet_eq_dec:
  Query_eq (UDP_Packet.UDP_Packet).
econstructor. repeat decide equality; subst; try apply A_eq_dec.
destruct Payload. destruct Payload0. destruct (A_eq_dec x x0).
- subst; destruct (A_eq_dec t t0). subst; auto.
  right; intro. apply Eqdep_dec.inj_pair2_eq_dec in H. congruence.
  apply A_eq_dec.
- right; intro. congruence.
Defined.

Instance chain_eq_dec:
  Query_eq chain.
econstructor. intros; destruct a; destruct a';
                try (left; solve [auto]); try (right; congruence).
Defined.

Instance Enum_eq_dec:
  forall n T v, Query_eq (@EnumType.EnumType n T v).
econstructor. unfold EnumType.EnumType. apply Fin.eq_dec. Defined.


Instance input_Query_eq:
  Query_eq input.
econstructor; decide equality; try apply A_eq_dec;
  decide equality; apply A_eq_dec. Defined.


Theorem SharpenNoIncomingFilter:
  FullySharpened NoIncomingConnectionsFilter.
Proof.
  start sharpening ADT. Transparent QSInsert.
  drop_constraints_under_bind PacketHistorySchema ltac:(
    intro v; intros Htemp;
    match goal with
      [H: DropQSConstraints_AbsR _ _ |- _] =>
      apply (UnConstrPreservesFilterMethod _ _ _ _ H)
    end;
    apply Htemp).

  (* hone_finite_under_bind PacketHistorySchema myqidx. *)


  hone representation using LessHistoryRelation;
    try simplify with monad laws.
  - refine pick val (DropQSConstraints (QSEmptySpec _));
      subst H; [reflexivity | apply LessHistoryRelationRefl].
    red; split; [reflexivity | apply QSEmptyFinite].
    
  - simpl. etransitivity. 2: (subst H; higher_order_reflexivity).
    apply refine_bind.
    apply (LessHistoryPreservesFilter d r_o r_n H0).

    red; intros;
      instantiate (1:=(fun a => r <- RefinedInsert r_n d; ret (r, a)));
      cbv beta; unfold RefinedInsert; unfold If_Then_Else;
      destruct (cf_cond OutgoingRule d) eqn:out; red; intros;
      repeat comp_inv;
      [ rename x0 into idx; rename H1 into Hidx;
        rename v into r; rename H4 into Hr; rename H3 into Hret
      | subst
      ];
      unfold LessHistoryRelation in H0; destruct H0 as [Hfin Hles];
      destruct Hfin as [HH Hfin]; unfold FiniteEnsemble in Hfin;
      pose proof Hfin as Hfinorig; specialize Hfin with Fin.F1;
      destruct Hfin as [lfin [lfin' Hlfin]].
      
    1-4: computes_to_econstructor;
      try apply (incrMaxFreshIdx_computes r_o lfin lfin' Hlfin);
      computes_to_econstructor; try reflexivity;
      computes_to_econstructor;
      red; split.

    all: repeat match goal with
      | [ |- FiniteTables_AbsR _ _ ] =>
        red; split; try reflexivity;
        intros finidx; destruct (Fin.eqb finidx myqidx) eqn:Hfeq

      | [Hfeq: Fin.eqb _ _ = false |- _] =>
        rewrite get_update_unconstr_neq;
        [ specialize Hfinorig with finidx; red; assumption
        | intro; subst finidx; compute in Hfeq; inversion Hfeq ]

      | [ |- FiniteEnsemble _ ] =>
        red; apply Fin.eqb_eq in Hfeq; rewrite Hfeq;
        exists ((icons2 d inil2) :: lfin);
        rewrite get_update_unconstr_eq;
        red; exists (({| elementIndex := incrMaxFreshIdx lfin';
                         indexedElement := icons2 d inil2 |}) :: lfin');
        destruct Hlfin as [Hmap [Heqv Hdup]]; split; [ | split ]

      | [ |- map _ _ = _ ] =>
        simpl; rewrite <- Hmap; reflexivity

      | [ |- NoDup _ ] =>
        cbn; constructor;
        try (unfold incrMaxFreshIdx; intro;
             apply (list_helper _ _ _ (Nat.lt_succ_diag_r _)) in H0);
        solve [auto]

      | [ |- forall _, In _ _ _ <-> List.In _ _ ] =>
        intros xelem; split; intros Hin; destruct Hin as [Hin | Hin];
        solve [ left; auto | right; apply Heqv in Hin; auto ]
    end.

    all: intros inp Hinp; split; repeat rewrite get_update_unconstr_eq;
      intros Hoin; try destruct Hoin as [eid [Hoin | Hoin]].
    * inversion Hoin; exists (incrMaxFreshIdx lfin');
      red; red; left; auto.
    * assert (Hoin': IndexedEnsemble_In
                       (GetUnConstrRelation r_n myqidx)
                       < sINPUT :: inp >) by (exists eid; apply Hoin).
      apply (Hles inp Hinp) in Hoin'. red.
      destruct Hoin' as [eid' Hoin']. exists eid'.
      red; red; right. apply Hoin'.
    * inversion Hoin; exists idx; red; red; left; auto.
    * assert (Hoin': IndexedEnsemble_In
                       (GetUnConstrRelation r_o myqidx)
                       < sINPUT :: inp >) by (exists eid; apply Hoin).
      apply (Hles inp Hinp) in Hoin'. red.
      destruct Hoin' as [eid' Hoin']. exists eid'.
      red; red; right. apply Hoin'.
    * apply (Hles inp Hinp) in Hoin; red; destruct Hoin as [eid Hoin];
      exists eid; red; red; right; auto.
    * inversion Hoin; congruence.
    * assert (Hoin': IndexedEnsemble_In
                       (GetUnConstrRelation r_o myqidx)
                       < sINPUT :: inp >) by (exists eid; apply Hoin).
      apply (Hles inp Hinp) in Hoin'. red.
      destruct Hoin' as [eid' Hoin']. exists eid'. apply Hoin'.



  - hone method "Filter".
    subst r_o. refine pick eq. simplify with monad laws.
    apply refine_bind. apply CompPreservesFilterMethod. intro.
    apply refine_bind. reflexivity. intro. simpl. higher_order_reflexivity.


Notation IndexType sch :=
  (@ilist3 RawSchema (fun sch : RawSchema =>
                        list (string * Attributes (rawSchemaHeading sch)))
           (numRawQSschemaSchemas sch) (qschemaSchemas sch)).


Definition indexes : IndexType PacketHistorySchema :=
  {| prim_fst := [("EqualityIndex", sINPUT # sHISTORY ## PacketHistorySchema)];
     prim_snd := () |}.


Ltac FindAttributeUses := EqExpressionAttributeCounter.
Ltac BuildEarlyIndex := ltac:(LastCombineCase6 BuildEarlyEqualityIndex).
Ltac BuildLastIndex := ltac:(LastCombineCase5 BuildLastEqualityIndex).
Ltac IndexUse := EqIndexUse.
Ltac createEarlyTerm := createEarlyEqualityTerm.
Ltac createLastTerm := createLastEqualityTerm.
Ltac IndexUse_dep := EqIndexUse_dep.
Ltac createEarlyTerm_dep := createEarlyEqualityTerm_dep.
Ltac createLastTerm_dep := createLastEqualityTerm_dep.
Ltac BuildEarlyBag := BuildEarlyEqualityBag.
Ltac BuildLastBag := BuildLastEqualityBag.
Ltac PickIndex := ltac:(fun makeIndex => let attrlist' := eval compute in indexes in makeIndex attrlist').


Ltac mydrill_step :=
  match goal with
  | [|- refine (Bind _ _) _] => eapply refine_bind
  end.
Ltac mydrill := repeat mydrill_step.


    PickIndex ltac:(fun attrlist =>
                      make_simple_indexes attrlist BuildEarlyIndex BuildLastIndex).

    * plan CreateTerm EarlyIndex LastIndex makeClause_dep EarlyIndex_dep LastIndex_dep.
    * etransitivity. simplify with monad laws.
      mydrill.
      unfold FilterMethod_UnConstr_Comp.
      eapply refine_If_Then_Else. reflexivity.
      eapply refine_If_Then_Else. reflexivity.

    match goal with
    [ H : @DelegateToBag_AbsR ?qs_schema ?indices ?r_o ?r_n
      |- refine (Bind (Count For (UnConstrQuery_In _ ?idx (fun tup => Where (@?P tup) Return (@?f tup))))
                      _) _ ] =>
    pose (@DecideableEnsembles.dec _ P _) as filter_dec;
      pose (ith3 indices idx) as idx_search_update_term;
      pose (BagSearchTermType idx_search_update_term) as search_term_type';
      pose (BagMatchSearchTerm idx_search_update_term) as search_term_matcher; simpl in *
    end.
    
(*  match goal with
    [ H : @DelegateToBag_AbsR ?qs_schema ?indices ?r_o ?r_n
      |- refine (Bind (Count For (UnConstrQuery_In _ ?idx (fun tup => Where (@?P tup) Return (@?f tup))))
                 _) _ ] =>
                    makeEvar search_term_type'
                             ltac: (fun search_term =>
                                      let eqv := fresh in
                                      assert (ExtensionalEq filter_dec (search_term_matcher search_term)) as eqv
                                      [ find_search_term qs_schema idx filter_dec search_term
                                      |
                                                                                                          [ |
  let H' := fresh in
  pose proof (@refine_BagFindBagCount
    _
    qs_schema indices
    idx r_o r_n search_term P f H eqv) as H';
    fold_string_hyps_in H'; fold_heading_hyps_in H';
    rewrite H'; clear H' eqv
                                                                                                          )
  end.*)

  Ltac createTerm f fds tail fs EarlyIndex LastIndex k ::=
  lazymatch fs with
  | [ ] => k tail
  | [{| KindIndexKind := ?kind;
        KindIndexIndex := ?s|} ] =>
    (findMatchingTerm
       fds kind s
       ltac:(fun X => k (Some X, tail)))
    || k (@None (Domain f s), tail)
  end.

  Ltac find_simple_search_term
     ClauseMatch EarlyIndex LastIndex
     qs_schema idx filter_dec search_term :=
  match type of search_term with
  | BuildIndexSearchTerm ?indexed_attrs =>
    let SC := constr:(GetNRelSchemaHeading (qschemaSchemas qs_schema) idx) in
    findGoodTerm SC filter_dec indexed_attrs ClauseMatch
                 ltac:(fun fds tail =>
                         let tail := eval simpl in tail in
                             makeTerm indexed_attrs SC fds tail EarlyIndex LastIndex ltac:(fun tm => pose tm (*unify tm search_term;
                                                                                           unfold ExtensionalEq, MatchIndexSearchTerm;
                                                                                           simpl; intro; try prove_extensional_eq*)
                      )) end.


  evar (x: search_term_type'). red in (type of x).
  assert (ExtensionalEq filter_dec (search_term_matcher x)) as eqv.
  ltac:(find_simple_search_term CreateTerm EarlyIndex LastIndex PacketHistorySchema myqidx filter_dec x).

  unfold ExtensionalEq, MatchIndexSearchTerm; simpl; intro.
  subst x. instantiate (1:=(None, filter_dec)). reflexivity.

    match goal with
    [ H : @DelegateToBag_AbsR ?qs_schema ?indices ?r_o ?r_n
      |- refine (Bind (Count For (UnConstrQuery_In _ ?idx (fun tup => Where (@?P tup) Return (@?f tup))))
                      _) _ ] =>
    pose f; pose P; pose indices
    end.

    Check @refine_BagFindBagCount. pose (BagMatchSearchTerm (ith3 i myqidx) x). change (search_term_matcher x) with b in eqv. subst b.

    assert (filter_dec_dec: forall a, filter_dec a = true <-> P a).
    { intros. unfold filter_dec. rewrite !bool_dec_simpl.
      unfold P. reflexivity. }
    
    pose {| dec := filter_dec; dec_decides_P := filter_dec_dec |} as P'.
    
    pose proof (@refine_BagFindBagCount
                  _
                  PacketHistorySchema i
                  myqidx r_o r_n x P u P' H0 eqv) as H';
      fold_string_hyps_in H'; fold_heading_hyps_in H'.
    unfold P, u in H'.
      rewrite H'; clear H' eqv.
      simplify with monad laws.

      reflexivity. red; intros.


      unfold RefinedInsert. etransitivity.
      apply refine_If_Then_Else_Bind.
      apply refine_If_Then_Else.

      simplify with monad laws. simpl.
      insertion IndexUse createEarlyTerm createLastTerm IndexUse_dep createEarlyTerm_dep createLastTerm_dep.
      simplify with monad laws; simpl. refine pick val r_n.
      simplify with monad laws; reflexivity. assumption.

      subst H. higher_order_reflexivity.

    * Locate "?[".

      
(*
Definition sID := "ID".
Definition sPACKET := "Packet".

Record Packet := packet
  { tcp_p: TCP_Packet;
    ip_h: IPv4_Packet; }.

Definition sHISTORY := "Packet History".

Definition PacketHistorySchema :=
  Query Structure Schema
    [ relation sHISTORY has
              schema < sID :: nat,
                       sPACKET :: Packet > ]
      enforcing [].

(* Definition Packet := TupleDef PacketHistorySchema sHISTORY.
 *)
Definition FilterSig : ADTSig :=
    ADTsignature {
        Constructor "Init" : rep,
        Method "Filter" : rep * Packet -> rep * bool
    }.

(** spec examples **)


(* Disallow all cross-domain SSH *)
(* --> if dst-port == 22 and src-domain != dst-domain, fail, else pass *)
Definition CrossDomain22FilterSpec : ADT FilterSig :=
    Eval simpl in Def ADT {
        rep := QueryStructure PacketHistorySchema,
        Def Constructor0 "Init" : rep := empty,,

        Def Method1 "Filter" (r: rep) (p: Packet) : rep * bool :=
            ret (r, (fail_if_all [
              weqb (port 22) p.(tcp_p).(DestPort) ;
              negb (weqb (domain_of p.(ip_h).(SourceAddress)) (domain_of p.(ip_h).(DestAddress)))
            ]))
    }%methDefParsing.


(* Allow FTP transfers from domain 3 to domains 1 and 2, but disallow FTP transfers from 1 and 2 to 3 *)
(* assuming this means domain 3 cannot initiate any FTP requests in 1 and 2 *)
(* --> if dst-port == 21 and src-domain == 3 and dst-domain == 1 or 2, fail, else pass *)
Definition Trusted21FilterSpec : ADT FilterSig :=
    Eval simpl in Def ADT {
        rep := QueryStructure PacketHistorySchema,
        Def Constructor0 "Init" : rep := empty,,

        Def Method1 "Filter" (r: rep) (p: Packet) : rep * bool :=
            ret (r, (fail_if_all [
              (weqb (p.(tcp_p).(DestPort)) (port 21)) ;
              (weqb (domain_of (p.(ip_h).(SourceAddress))) (domain 130)) ;
              (fail_if_any [
                (weqb (domain_of (p.(ip_h).(DestAddress))) (domain 110)) ;
                (weqb (domain_of (p.(ip_h).(DestAddress))) (domain 120))
              ])
            ]))
    }%methDefParsing.
*)

Record SimplePacket := 
  { id: nat }.

Definition SimpleFilterSig : ADTSig :=
  ADTsignature {
      Constructor "Init" : rep,
      Method "Filter" : rep * SimplePacket -> rep * bool
  }.

Definition SimplePacketHistorySchema :=
  Query Structure Schema
    [ relation sHISTORY has
              schema < sPACKET :: SimplePacket > ]
      enforcing [].



Definition isIDHighest (r: QueryStructure SimplePacketHistorySchema) (p: SimplePacket) : Comp bool :=
(*     vals <- For (pac in r!sHISTORY) Return ((pac!sPACKET).(id)); *)
    { h: bool | decides h (forall pac, IndexedEnsemble_In ((DropQSConstraints r)!sHISTORY)%QueryImpl pac
        -> lt (pac!sPACKET).(id) p.(id)) }.

(* rephrase with Ensembles predicate, finiteness not necessary *)


Definition IncrementIDFilterSpec : ADT SimpleFilterSig :=
    Eval simpl in Def ADT {
        rep := QueryStructure SimplePacketHistorySchema,
        Def Constructor0 "Init" : rep := empty,,

        Def Method1 "Filter" (r: rep) (p: SimplePacket) : rep * bool :=
            isHighest <- isIDHighest r p;
            `(r, _) <- Insert (< sPACKET :: p >) into r!sHISTORY;
            ret (r, isHighest)
    }%methDefParsing.


Theorem SharpenedIncrementIDFilter:
  FullySharpened IncrementIDFilterSpec.
Proof.

  Definition repHighestID (oldrep: QueryStructure SimplePacketHistorySchema) (newrep: option nat) :=
    match newrep with
    | Some n =>
      (forall pac, IndexedEnsemble_In (((DropQSConstraints oldrep)!sHISTORY)%QueryImpl) pac -> le (pac!sPACKET).(id) n)
      /\ (exists pac, IndexedEnsemble_In (((DropQSConstraints oldrep)!sHISTORY)%QueryImpl) pac /\ (pac!sPACKET).(id) = n)
    | None => oldrep = QSEmptySpec SimplePacketHistorySchema
    end.
  
  Lemma isIDHighestCompute:
    forall r_o r_n p, (repHighestID r_o r_n) ->
      computes_to (isIDHighest r_o p)
        (match r_n with
         | Some n => (Nat.ltb n p.(id))
         | None => true
         end).
  Proof.
    intros. destruct r_n.
    - eapply PickComputes. unfold decides, If_Then_Else.
      destruct (n <? id p) eqn:rnpid. 
      + intros. apply H in H0. apply Nat.ltb_lt in rnpid. intuition.
      + unfold not. intros. destruct H. apply Nat.ltb_ge in rnpid.
        assert (Hp: forall pac: RawTuple,
          IndexedEnsemble_In ((DropQSConstraints r_o)!sHISTORY)%QueryImpl pac ->
          (lt (id pac!sPACKET) n)). { intros. apply H0 in H2. apply (Nat.lt_le_trans _ _ _ H2 rnpid). }
        destruct H1 as [pac Hpac]. specialize (Hp pac). destruct Hpac as [HpacIn Hpacn].
        rewrite Hpacn in Hp. apply Hp, Nat.lt_neq in HpacIn. apply HpacIn. reflexivity.
    - eapply PickComputes. unfold decides, If_Then_Else. unfold repHighestID in H. subst.
      intros. unfold QSEmptySpec in H. compute in H. destruct H. inversion H.
  Qed.

  Lemma isIDHighestRefine:
    forall r_o r_n p, (repHighestID r_o r_n) ->
      refine (isIDHighest r_o p)
        (ret match r_n with
            | Some n => (Nat.ltb n p.(id))
            | None => true
            end).
  Proof.
    intros. unfold refine in *. intros. computes_to_inv. subst. apply isIDHighestCompute, H.
  Qed.

(*  Definition findHighestID (r_o: UnConstrQueryStructure SimplePacketHistorySchema) : option nat.
    unfold UnConstrQueryStructure in r_o.
    pose (ilist2_hd r_o). simpl in y. Transparent RawUnConstrRelation. unfold RawUnConstrRelation in y. Check y!sPACKET.*)

  start sharpening ADT.
(*  hone representation using (@DropQSConstraints_AbsR SimplePacketHistorySchema); try simplify with monad laws; unfold refine.
  - intros. computes_to_econstructor. unfold DropQSConstraints_AbsR. unfold DropQSConstraints. simpl. Transparent computes_to. apply H0.
  - intros. computes_to_econstructor. apply isIDHighestCompute.*)

    
    hone representation using repHighestID; unfold repHighestID in *.
  - simplify with monad laws. refine pick val (@None nat). subst H. reflexivity. reflexivity.
  - simplify with monad laws. unfold refine. intros. computes_to_econstructor. apply isIDHighestCompute. apply H0. repeat computes_to_econstructor.
Abort.

(*
Definition SYNFloodFilterSpec : ADT FilterSig :=
    Eval simpl in Def ADT {
        rep := QueryStructure PacketHistorySchema,
        Def Constructor0 "Init" : rep := empty,,

        Def Method1 "Filter" (r: rep) (p: Packet) : rep * bool :=
            src_addr <- ret p.(ip_h)!SourceAddress;
            dst_addr <- ret p.(ip_h)!DestAddress;
            src_port <- ret p.(tcp_p)!SourcePort;
            dst_port <- ret p.(tcp_p)!DestPort;
            conns <- Count (For (pac in r!sHISTORY)
                            Where (src_addr = pac.(ip_h)!SourceAddress)
                            Where (dst_addr = pac.(ip_h)!DestAddress)
                            Where (dst_port = pac.(tcp_p)!DestPort)
                            Return ())
    }%methDefParsing.*)


(* spec a filter that ensures every packet has a higher id than previous
   specify concretely how we are ensuring this: get/put +1 *)
(* spec a filter for example #3 from email *)
(* break down master_plan and try to sharpen filter -- write a tactic, read master_plan *)

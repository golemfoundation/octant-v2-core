requires "evm.md"
requires "foundry.md"
// requires "keccak.md"

module OCTANT-LEMMAS
    imports EVM
    imports FOUNDRY
    imports INT-SYMBOLIC
    imports MAP-SYMBOLIC
    imports SET-SYMBOLIC

    syntax StepSort ::= Int
                      | Bool
                      | Bytes
                      | Map
                      | Set
 // -------------------------

    syntax KItem ::= runLemma ( StepSort )
                   | doneLemma( StepSort )
 // --------------------------------------
    rule <k> runLemma(T) => doneLemma(T) ... </k>

    //
    //  Arithmetic
    //
    rule C <=Int A *Int B => C /Int A <=Int B
      requires 0 <=Int C andBool 0 <Int A
       andBool C modInt A ==Int 0
       [simplification(40), concrete(C, A), preserves-definedness]

    rule A ==Int B => false
      requires 0 <=Int A andBool B <Int 0
      [simplification, concrete(B)]

    rule 0 <=Int A -Int B => B <=Int A
      [simplification, symbolic(A, B)]

    rule (A *Int (B *Int C)) => (A *Int B) *Int C
      [simplification, concrete(A, B)]

    rule (A *Int B) /Int C => ((A /Int 10) *Int B) /Int (C /Int 10)
      requires notBool (C ==Int 0) andBool A modInt 10 ==Int 0 andBool C modInt 10 ==Int 0
      [simplification, concrete(A, C), preserves-definedness]

    rule A /Int (B *Int C) => (A /Int 10) /Int ((B /Int 10) *Int C)
      requires notBool (B ==Int 0) andBool notBool (C ==Int 0)
       andBool A modInt 10 ==Int 0 andBool B modInt 10 ==Int 0
      [simplification, concrete(A, B), preserves-definedness]

    // Instantiation of the Kontrol lemma
    // rule ( X ==Int ( X *Int Y ) /Word Y ) orBool Y ==Int 0 => true [simplification, preserves-definedness]
    // when Y is of the form Y *Int Z, because then the `Y ==Int 0` condition gets simplified to a different form
    rule ( X ==Int ( X *Int (Y *Int Z) ) /Word (Y *Int Z) ) orBool (Y ==Int 0 orBool Z ==Int 0) => true [simplification, preserves-definedness]

    // Instantiation of the Kontrol lemma
    // rule ( X ==Int ( X *Int Y ) /Word Y ) orBool Y ==Int 0 => true [simplification, preserves-definedness]
    // when Y is of the form Y *Int ( Z *Int T ), because then the `Y ==Int 0` condition gets simplified to a different form
    rule ( X ==Int ( X *Int (Y *Int (Z *Int T)) ) /Word (Y *Int (Z *Int T)) ) orBool (Y ==Int 0 orBool (Z ==Int 0 orBool T ==Int 0)) => true [simplification, preserves-definedness]

    // Instantiation of the Kontrol lemma
    // rule ( X ==Int ( X *Int Y ) /Word Y ) orBool Y ==Int 0 => true [simplification, preserves-definedness]
    // when Y is of the form Y /Int Z, because then the `Y ==Int 0` condition gets simplified to a different form
    rule ( X ==Int ( X *Int (Y /Int Z) ) /Word (Y /Int Z) ) orBool Y <Int Z => true
      requires notBool ( Z ==Int 0 )
      [simplification, preserves-definedness]

    rule [chop-sub]:
      chop ( Y -Int X:Int ) ==Int 0 => X ==Int Y
      requires #rangeUInt(256, X) andBool #rangeUInt(256, Y)
      [simplification, concrete(Y), comm]

    rule ( chop ( X:Int ) -Int bool2Word (Y) ) ==Int 0 => chop ( X:Int ) ==Int 0
      requires notBool Y
      [simplification]

    rule ( chop ( X:Int ) -Int bool2Word (Y) ) ==Int 0 => chop ( X:Int ) ==Int 1
      requires Y
      [simplification]

    rule [keccak-slots-disjoint-l]:
      keccak ( A ) ==Int keccak ( B ) +Int C => false
      requires notBool 0 ==Int C
      [simplification, concrete(C), comm]

    rule [keccak-slots-disjoint-ml-l]:
      { keccak ( A ) #Equals keccak ( B ) +Int C } => #Bottom
      requires notBool 0 ==Int C
      [simplification, concrete(C)]

    rule [keccak-slots-disjoint-ml-r]:
      { keccak ( B ) +Int C #Equals keccak ( A ) } => #Bottom
      requires notBool 0 ==Int C
      [simplification, concrete(C)]

    rule ( SetItem(X:Int) S:Set ) |Set SetItem(Y:Int) => SetItem(X) ( S |Set SetItem (Y) ) requires notBool X ==Int Y [simplification, preserves-definedness]
    rule ( SetItem(X:Int) S:Set ) |Set SetItem(Y:Int) => SetItem(X) S                      requires         X ==Int Y [simplification, preserves-definedness]
    rule                     .Set |Set SetItem(X:Int) => SetItem(X)                                                   [simplification, preserves-definedness]

    rule K1 in_keys((K2 |-> _ ) M) => K1 ==Int K2 orBool K1 in_keys(M) [simplification]

    rule [transferFunds-hp-neq]:
      <k> #transferFunds ACCTFROM ACCTTO VALUE => .K ... </k>
      <account>
        <acctID> ACCTFROM </acctID>
        <balance> ORIGFROM => ORIGFROM -Word VALUE </balance>
        ...
      </account>
      <account>
        <acctID> ACCTTO </acctID>
        <balance> ORIGTO => ORIGTO +Word VALUE </balance>
        ...
      </account>
      requires ACCTFROM =/=K ACCTTO andBool VALUE <=Int ORIGFROM
      [priority(30), preserves-definedness]

    rule [accounts-in-keys]:
      `AccountCellMap:in_keys`(
        <acctID> (X:Int) </acctID>,
        (`_AccountCellMap_`(AccountCellMapItem(<acctID> Y:Int </acctID>, _:AccountCell):AccountCellMap, ACCOUNTS_REST:AccountCellMap)):AccountCellMap
      ) => X ==Int Y orBool `AccountCellMap:in_keys`(<acctID> (X:Int) </acctID>, ACCOUNTS_REST)
      [simplification, preserves-definedness]

    rule (A *Int B) -Int (B *Int A) => 0
     [simplification, preserves-definedness]

    //
    // ceilDiv property for PPS non-decreasing in loss-with-burning
    //
    // Property: D * ceilDiv(N, D) >= N
    // OZ Math.mulDiv with Ceil computes: floor(N/D) + bool2Word(N mod D > 0)
    //
    // Proof sketch:
    //   Let N = D*q + r where 0 <= r < D.
    //   Case r = 0: ceilDiv = q,     D*q     = N.           (>= N holds)
    //   Case r > 0: ceilDiv = q + 1, D*(q+1) = N - r + D.  (>= N since D > r)
    //
    // If these lemmas don't match the exact K term, use:
    //   kontrol show 'YDStrategyTest.testReportLossWithBurning()' --pending
    // to inspect the stuck term and adjust the pattern.
    //

    //
    // ProperQF quantization lemmas (shift-32 encode/decode)
    //
    // The EVM compiles `value >> 32` then `encoded << 32` into byte operations:
    //   encode: extracts upper 28 bytes via #buf(28, value /Int pow32)
    //   decode: appends 4 zero bytes and reads as uint256 via #asWord
    // K leaves these as symbolic #buf/#asWord terms. These lemmas close the gap.
    //

    // L1: decode(encode(x)) == x for step-aligned values
    // Pattern from `kontrol show`: #asWord(#buf(28, X /Int pow32) +Bytes b"\x00\x00\x00\x00") ==Int X
    rule [quant-decode-encode]:
      #asWord ( #buf ( 28 , ( X /Int pow32 ) ) +Bytes b"\x00\x00\x00\x00" ) => X
      requires 0 <=Int X andBool X <Int pow256
       andBool X modInt pow32 ==Int 0
      [simplification, preserves-definedness]

    // L1b: #asWord(#buf(30, k) ++ 0x0000) == k * pow16 (weight = k * MIN_VOTE_WEIGHT)
    // Appears in P10 when K represents weight = k * 2^16 via byte concatenation
    rule [quant-weight-from-k]:
      #asWord ( #buf ( 30 , K ) +Bytes b"\x00\x00" ) => K *Int pow16
      requires 0 <=Int K andBool K <Int pow240
      [simplification, preserves-definedness]

    // L2: low 4 bytes of step-aligned value are zero
    // Pattern from `kontrol show`: #range(#buf(32, X), 28, 4) ==K b"\x00\x00\x00\x00"
    rule [quant-low-bytes-zero]:
      #range ( #buf ( 32 , X ) , 28 , 4 ) => b"\x00\x00\x00\x00"
      requires 0 <=Int X andBool X <Int pow256
       andBool X modInt pow32 ==Int 0
      [simplification, preserves-definedness]

    rule [ceilDiv-ge]:
      D *Int ( ( N /Int D ) +Int bool2Word ( 0 <Int ( N modInt D ) ) ) >=Int N => true
      requires 0 <Int D andBool 0 <=Int N
      [simplification, preserves-definedness]

    rule [ceilDiv-le]:
      N <=Int D *Int ( ( N /Int D ) +Int bool2Word ( 0 <Int ( N modInt D ) ) ) => true
      requires 0 <Int D andBool 0 <=Int N
      [simplification, preserves-definedness]

endmodule

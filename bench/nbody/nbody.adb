-- nbody, configuration 8: Ada, the design PROPOSAL.md copies.
--
-- Ada is the high-water mark in RESEARCH.md section 2's ranking of standards,
-- above Common Lisp, because it names each check individually and lets you
-- suppress them at any scope with pragma Suppress. CL bundles every risk into
-- one 0-3 safety dial.
--
-- Three build configurations, selected by -gnateDPOLICY in configs.sh, so this
-- one source measures all three:
--
--   POLICY=0  every check on. Ada's default, and note that this is a STRONGER
--             default than C: Index_Check, Range_Check and Overflow_Check are
--             all on unless suppressed.
--   POLICY=1  named per-check suppression. The design we are copying.
--   POLICY=2  pragma Suppress (All_Checks). The blunt instrument, for
--             comparison against POLICY=1.
--
-- LEDGER.md D5 is status:draft precisely pending this. If All_Checks beats
-- named suppression meaningfully, granularity has a price and the proposal
-- needs rewriting.
--
-- Written from SPEC.md. Expression order matches ref.c exactly.

with Ada.Text_IO;
with Ada.Command_Line;
with Ada.Numerics;
with Ada.Numerics.Long_Elementary_Functions;

procedure Nbody is

   package TIO renames Ada.Text_IO;
   package Math renames Ada.Numerics.Long_Elementary_Functions;

   --  @SUPPRESS@  configs.sh substitutes the named pragma Suppress lines here
   --  for the ada-8-named build and leaves this line alone otherwise. Keeping
   --  one source means the three policies differ ONLY in the pragmas, which is
   --  what makes the comparison mean anything.

   Pi            : constant Long_Float := 3.141592653589793;
   Solar_Mass    : constant Long_Float := 4.0 * Pi * Pi;
   Days_Per_Year : constant Long_Float := 365.24;
   Dt            : constant Long_Float := 0.01;
   Nbody_Count   : constant := 5;
   Slots         : constant := 7;

   type Body_Array is array (Natural range 0 .. Nbody_Count * Slots - 1) of Long_Float;
   B : Body_Array := (others => 0.0);

   function G (I, K : Natural) return Long_Float is
   begin
      return B (I * Slots + K);
   end G;

   procedure S (I, K : Natural; V : Long_Float) is
   begin
      B (I * Slots + K) := V;
   end S;

   procedure Put (I : Natural; X, Y, Z, Vx, Vy, Vz, M : Long_Float) is
   begin
      S (I, 0, X); S (I, 1, Y); S (I, 2, Z);
      S (I, 3, Vx * Days_Per_Year);
      S (I, 4, Vy * Days_Per_Year);
      S (I, 5, Vz * Days_Per_Year);
      S (I, 6, M * Solar_Mass);
   end Put;

   procedure Init is
   begin
      Put (0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0);
      Put (1, 4.84143144246472090E+00, -1.16032004402742839E+00, -1.03622044471123109E-01,
              1.66007664274403694E-03, 7.69901118419740425E-03, -6.90460016972063023E-05,
              9.54791938424326609E-04);
      Put (2, 8.34336671824457987E+00, 4.12479856412430479E+00, -4.03523417114321381E-01,
              -2.76742510726862411E-03, 4.99852801234917238E-03, 2.30417297573763929E-05,
              2.85885980666130812E-04);
      Put (3, 1.28943695621391310E+01, -1.51111514016986312E+01, -2.23307578892655734E-01,
              2.96460137564761618E-03, 2.37847173959480950E-03, -2.96589568540237556E-05,
              4.36624404335156298E-05);
      Put (4, 1.53796971148509165E+01, -2.59193146099879641E+01, 1.79258772950371181E-01,
              2.68067772490389322E-03, 1.62824170038242295E-03, -9.51592254519715870E-05,
              5.15138902046611451E-05);
   end Init;

   procedure Offset_Momentum is
      Px, Py, Pz : Long_Float := 0.0;
   begin
      for I in 0 .. Nbody_Count - 1 loop
         Px := Px + G (I, 3) * G (I, 6);
         Py := Py + G (I, 4) * G (I, 6);
         Pz := Pz + G (I, 5) * G (I, 6);
      end loop;
      S (0, 3, (0.0 - Px) / Solar_Mass);
      S (0, 4, (0.0 - Py) / Solar_Mass);
      S (0, 5, (0.0 - Pz) / Solar_Mass);
   end Offset_Momentum;

   --  Velocities from forces at current positions, then positions. Not fused.
   procedure Advance is
      Dx, Dy, Dz, D2, Mag, Mi, Mj : Long_Float;
   begin
      for I in 0 .. Nbody_Count - 1 loop
         for J in I + 1 .. Nbody_Count - 1 loop
            Dx := G (I, 0) - G (J, 0);
            Dy := G (I, 1) - G (J, 1);
            Dz := G (I, 2) - G (J, 2);
            D2 := Dx * Dx + Dy * Dy + Dz * Dz;
            Mag := Dt / (D2 * Math.Sqrt (D2));
            Mj := G (J, 6) * Mag;
            Mi := G (I, 6) * Mag;
            S (I, 3, G (I, 3) - Dx * Mj);
            S (I, 4, G (I, 4) - Dy * Mj);
            S (I, 5, G (I, 5) - Dz * Mj);
            S (J, 3, G (J, 3) + Dx * Mi);
            S (J, 4, G (J, 4) + Dy * Mi);
            S (J, 5, G (J, 5) + Dz * Mi);
         end loop;
      end loop;
      for I in 0 .. Nbody_Count - 1 loop
         S (I, 0, G (I, 0) + Dt * G (I, 3));
         S (I, 1, G (I, 1) + Dt * G (I, 4));
         S (I, 2, G (I, 2) + Dt * G (I, 5));
      end loop;
   end Advance;

   function Energy return Long_Float is
      E, Dx, Dy, Dz, D : Long_Float;
   begin
      E := 0.0;
      for I in 0 .. Nbody_Count - 1 loop
         E := E + 0.5 * G (I, 6) *
              (G (I, 3) * G (I, 3) + G (I, 4) * G (I, 4) + G (I, 5) * G (I, 5));
         for J in I + 1 .. Nbody_Count - 1 loop
            Dx := G (I, 0) - G (J, 0);
            Dy := G (I, 1) - G (J, 1);
            Dz := G (I, 2) - G (J, 2);
            D := Math.Sqrt (Dx * Dx + Dy * Dy + Dz * Dz);
            E := E - (G (I, 6) * G (J, 6)) / D;
         end loop;
      end loop;
      return E;
   end Energy;

   package LF_IO is new TIO.Float_IO (Long_Float);

   N : Natural := 1000;

begin
   if Ada.Command_Line.Argument_Count >= 1 then
      N := Natural'Value (Ada.Command_Line.Argument (1));
   end if;

   Init;
   Offset_Momentum;
   LF_IO.Put (Energy, Fore => 1, Aft => 9, Exp => 0);
   TIO.New_Line;
   for I in 1 .. N loop
      Advance;
   end loop;
   LF_IO.Put (Energy, Fore => 1, Aft => 9, Exp => 0);
   TIO.New_Line;
end Nbody;

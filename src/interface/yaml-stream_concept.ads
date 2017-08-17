--  part of AdaYaml, (c) 2017 Felix Krause
--  released under the terms of the MIT license, see the file "copying.txt"


generic
   type Instance is limited new Refcount_Base with private;
   type Reference (Data : not null access Instance) is tagged private;
   with function Next (Object : in out Instance) return Event;
package Yaml.Stream_Concept is
   pragma Warnings (Off, Next);
   pragma Warnings (Off, Reference);

   --  to not burden ourselves with too much dynamic dispatching, we define a
   --  Stream as anything that is able to instantiate this package. any consumer
   --  of a stream shall take as generic parameter an instance of this package.
end Yaml.Stream_Concept;

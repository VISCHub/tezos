(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2017.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

module Public_key_hash = Blake2B.Make(Base58)(struct
    let name = "Ed25519.Public_key_hash"
    let title = "An Ed25519 public key ID"
    let b58check_prefix = Base58.Prefix.ed25519_public_key_hash
    let size = Some 20
  end)

let () =
  Base58.check_encoded_prefix Public_key_hash.b58check_encoding "tz1" 36

module Public_key = struct

  type t = Sodium.Sign.public_key
  let compare = Sodium.Sign.compare_public_keys
  let (=) xs ys = compare xs ys = 0
  let (<>) xs ys = compare xs ys <> 0
  let (<) xs ys = compare xs ys < 0
  let (<=) xs ys = compare xs ys <= 0
  let (>=) xs ys = compare xs ys >= 0
  let (>) xs ys = compare xs ys > 0
  let max x y = if x >= y then x else y
  let min x y = if x <= y then x else y

  type Base58.data +=
    | Public_key of t

  let b58check_encoding =
    Base58.register_encoding
      ~prefix: Base58.Prefix.ed25519_public_key
      ~length:Sodium.Sign.public_key_size
      ~to_raw:(fun x -> Bytes.to_string (Sodium.Sign.Bytes.of_public_key x))
      ~of_raw:(fun x ->
          try Some (Sodium.Sign.Bytes.to_public_key (Bytes.of_string x))
          with _ -> None)
      ~wrap:(fun x -> Public_key x)

  let of_b58check_opt s = Base58.simple_decode b58check_encoding s
  let of_b58check_exn s =
    match Base58.simple_decode b58check_encoding s with
    | Some x -> x
    | None -> Pervasives.failwith "Unexpected hash (ed25519 public key)"
  let of_b58check s =
    match Base58.simple_decode b58check_encoding s with
    | Some x -> Ok x
    | None -> generic_error "Unexpected hash (ed25519 public key)"
  let to_b58check s = Base58.simple_encode b58check_encoding s

  let of_bytes s = Sodium.Sign.Bytes.to_public_key s

  let param ?(name="ed25519-public") ?(desc="Ed25519 public key (b58check-encoded)") t =
    Cli_entries.(param ~name ~desc (parameter (fun _ str -> Lwt.return (of_b58check str))) t)

  let () =
    Base58.check_encoded_prefix b58check_encoding "edpk" 54

  let encoding =
    let open Data_encoding in
    splitted
      ~json:
        (describe
           ~title: "An Ed25519 public key (Base58Check encoded)" @@
         conv
           (fun s -> Base58.simple_encode b58check_encoding s)
           (fun s ->
              match Base58.simple_decode b58check_encoding s with
              | Some x -> x
              | None -> Data_encoding.Json.cannot_destruct
                          "Ed25519 public key: unexpected prefix.")
           string)
      ~binary:
        (conv
           Sodium.Sign.Bigbytes.of_public_key
           Sodium.Sign.Bigbytes.to_public_key
           (Fixed.bytes Sodium.Sign.public_key_size))

  let hash v =
    Public_key_hash.hash_bytes
      [ Sodium.Sign.Bigbytes.of_public_key v ]

end

module Secret_key = struct

  type t = Sodium.Sign.secret_key

  let to_public_key = Sodium.Sign.secret_key_to_public_key

  type Base58.data +=
    | Secret_key of t

  let b58check_encoding =
    Base58.register_encoding
      ~prefix: Base58.Prefix.ed25519_secret_key
      ~length:Sodium.Sign.secret_key_size
      ~to_raw:(fun x -> Bytes.to_string (Sodium.Sign.Bytes.of_secret_key x))
      ~of_raw:(fun x ->
          try Some (Sodium.Sign.Bytes.to_secret_key (Bytes.of_string x))
          with _ -> None)
      ~wrap:(fun x -> Secret_key x)

  let of_b58check_opt s = Base58.simple_decode b58check_encoding s
  let of_b58check_exn s =
    match Base58.simple_decode b58check_encoding s with
    | Some x -> x
    | None -> Pervasives.failwith "Unexpected hash (ed25519 secret key)"
  let of_b58check s =
    match Base58.simple_decode b58check_encoding s with
    | Some x -> Ok x
    | None -> generic_error "Unexpected hash (ed25519 public key)"
  let to_b58check s = Base58.simple_encode b58check_encoding s

  let of_bytes s = Sodium.Sign.Bytes.to_secret_key s

  let param ?(name="ed25519-secret") ?(desc="Ed25519 secret key (b58check-encoded)") t =
    Cli_entries.(param ~name ~desc (parameter (fun _ str -> Lwt.return (of_b58check str))) t)

  let () =
    Base58.check_encoded_prefix b58check_encoding "edsk" 98

  let encoding =
    let open Data_encoding in
    splitted
      ~json:
        (describe
           ~title: "An Ed25519 secret key (Base58Check encoded)" @@
         conv
           (fun s -> Base58.simple_encode b58check_encoding s)
           (fun s ->
              match Base58.simple_decode b58check_encoding s with
              | Some x -> x
              | None -> Data_encoding.Json.cannot_destruct
                          "Ed25519 secret key: unexpected prefix.")
           string)
      ~binary:
        (conv
           Sodium.Sign.Bigbytes.of_secret_key
           Sodium.Sign.Bigbytes.to_secret_key
           (Fixed.bytes Sodium.Sign.secret_key_size))

end

let sign key msg =
  Sodium.Sign.Bigbytes.(of_signature @@ sign_detached key msg)

module Signature = struct

  type t = MBytes.t

  type Base58.data +=
    | Signature of t

  let b58check_encoding =
    Base58.register_encoding
      ~prefix: Base58.Prefix.ed25519_signature
      ~length:Sodium.Sign.signature_size
      ~to_raw:MBytes.to_string
      ~of_raw:(fun s -> Some (MBytes.of_string s))
      ~wrap:(fun x -> Signature x)

  let of_b58check_opt s = Base58.simple_decode b58check_encoding s
  let of_b58check_exn s =
    match Base58.simple_decode b58check_encoding s with
    | Some x -> x
    | None -> Pervasives.failwith "Unexpected hash (ed25519 signature)"
  let of_b58check s =
    match Base58.simple_decode b58check_encoding s with
    | Some x -> Ok x
    | None -> generic_error "Unexpected hash (ed25519 public key)"
  let to_b58check s = Base58.simple_encode b58check_encoding s

  let of_bytes s = MBytes.of_string (Bytes.to_string s)

  let param ?(name="signature") ?(desc="Signature (b58check-encoded)") t =
    Cli_entries.(param ~name ~desc (parameter (fun _ str -> Lwt.return (of_b58check str))) t)

  let () =
    Base58.check_encoded_prefix b58check_encoding "edsig" 99

  let encoding =
    let open Data_encoding in
    splitted
      ~json:
        (describe
           ~title: "An Ed25519 signature (Base58Check encoded)" @@
         conv
           (fun s -> Base58.simple_encode b58check_encoding s)
           (fun s ->
              match Base58.simple_decode b58check_encoding s with
              | Some x -> x
              | None -> Data_encoding.Json.cannot_destruct
                          "Ed25519 signature: unexpected prefix.")
           string)
      ~binary: (Fixed.bytes Sodium.Sign.signature_size)

  let check public_key signature msg =
    try
      Sodium.Sign.Bigbytes.(verify public_key (to_signature signature) msg) ;
      true
    with _ -> false

  let append key msg =
    MBytes.concat msg (sign key msg)

  let concat msg signature =
    MBytes.concat msg signature

end

module Seed = struct

  type t = Sodium.Sign.seed

  let to_hex s =
    Sodium.Sign.Bytes.of_seed s
    |> Bytes.to_string
    |> Hex_encode.hex_encode

  let of_hex s =
    Hex_encode.hex_decode s
    |> Bytes.of_string
    |> Sodium.Sign.Bytes.to_seed

  let generate () =
    (* Seed is 32 bytes long *)
    Sodium.Random.Bytes.generate Sodium.Sign.seed_size
    |> Sodium.Sign.Bytes.to_seed

  let extract =
    Sodium.Sign.secret_key_to_seed
end

let generate_key () =
  let secret, pub = Sodium.Sign.random_keypair () in
  (Public_key.hash pub, pub, secret)

let generate_seeded_key seed =
  let secret, pub = Sodium.Sign.seed_keypair seed in
  (Public_key.hash pub, pub, secret)

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";

/// @notice Adapted from timurguvenkaya's multichain deployment script
///         https://github.com/timurguvenkaya/foundry-multichain/blob/main/script/BaseDeployer.s.sol
/* solhint-disable max-states-count */
contract BaseDeployer is Script {
    /// EXPECTED CONTRACT ADDRESSES ///
    address constant RELAY_RECEIVER =
        0xa06e1351E2fD2D45b5D35633ca7eCF328684a109;
    address constant ONLY_OWNER_MULTICALLER =
        0xb90ed4c123843cbFD66b11411Ee7694eF37E6E72;
    address constant APPROVAL_PROXY =
        0xfD06C0018318BF78705ccFf2b961Ef8eBC0bacA0;
    address constant ERC20_ROUTER = 0xE0B062D028236FA09Fe33dB8019FFEEEe6bF79Ed;
    address constant MULTICALLER_ARACHNID_CREATE2_FACTORY =
        0xB0E22F8B026c5dc4b0Bc33eF4C5d3231544aEE3e;
    address constant ERC20_ROUTER_ARACHNID_CREATE2_FACTORY =
        0x83095Af87DE31eF97ECCa8312493F42547A5ff2C;
    address constant APPROVAL_PROXY_ARACHNID_CREATE2_FACTORY =
        0xcdf11EF8FeB47C9a9498c4F89D71f1768fEADec7;
    /// FACTORY ADDRESSES ///
    address constant IMMUTABLE_CREATE2_FACTORY =
        0x0000000000FFe8B47B3e2130213B802212439497;
    address constant FOUNDRY_CREATE2_FACTORY =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// ROUTER ARGS ///
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address PERMIT2_ZKSYNC = 0x0000000000225e31D15943971F47aD3022F714Fa;
    address MULTICALLER = payable(0x0000000000002Bdbf1Bf3279983603Ec279CC6dF);
    /// @dev owner is deployer by default
    address owner = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

    /// RECEIVER ARGS ///
    address SOLVER = 0xf70da97812CB96acDF810712Aa562db8dfA3dbEF;
    address TESTNET_SOLVER = 0x3e34b27a9bf37D8424e1a58aC7fc4D06914B76B9;

    /// CREATE2 SALTS ///
    bytes32 constant ROUTER_SALT =
        0x0000000000000000000000000000000000000000177317f7617d575e615800c0;
    bytes32 constant RECEIVER_SALT =
        0xf3d63166f0ca56c3c1a3508fce03ff0cf3fb691eabb10b39452d27ff942e0020;
    bytes32 constant VECTORIZED_MULTICALLER_SALT =
        0x0000000000000000000000000000000000000000ef4834b251a91000a916248a;

    enum Chains {
        Amoy,
        Boss,
        Holesky,
        ArbitrumSepolia,
        SolanaDevnet,
        DeBankTestnet,
        MantaTestnet,
        Barret,
        ZkSyncSepolia,
        AlignTestnetV2,
        ModeTestnet,
        Bob,
        Goerli,
        GinTestnet,
        FrameTestnet,
        BlastSepolia,
        AstarZkyoto,
        Hypr,
        Hekla,
        OpSepolia,
        Garnet,
        Ancient8CelestiaTestnet,
        Atlas,
        B3,
        ZoraSepolia,
        FunkiTestnet,
        LiskSepolia,
        Cloud,
        Game7Testnet,
        ShapeSepolia,
        ArbitrumBlueberry,
        MIntegrationsTestnet,
        Sepolia,
        Memecoin2,
        BaseSepolia,
        Redstone,
        Rari,
        ZkSync,
        Degen,
        Linea,
        Avalanche,
        Zora,
        Polygon,
        Ancient8,
        Xai,
        AstarZkevm,
        Mode,
        Gnosis,
        Blast,
        Apex,
        Funki,
        Lisk,
        Ham,
        OnchainPoints,
        PolygonZkevm,
        ArbitrumNova,
        Taiko,
        Boba,
        Cyber,
        Arbitrum,
        Scroll,
        Mainnet,
        Bsc,
        Base,
        Mint,
        Optimism,
        BobTestnet,
        B3Sepolia,
        Creator,
        PopCloudTestnet,
        Secret,
        Mobl3Testnet,
        AllegedJadeLoon,
        Kekchain,
        EclipseTestnet,
        ZeroTestnet,
        ApeChain,
        UniChain,
        Mantle,
        BeraChain,
        Celo,
        Soneium,
        Sonic,
        Shape,
        Worldchain,
        Flow,
        Sei,
        Perennial,
        Story,
        Gravity,
        Swellchain,
        Sanko,
        Game7,
        Hychain,
        Echos,
        Powerloom,
        ArenaZ,
        Superposition,
        Ink,
        Forma,
        Eclipse,
        Ronin,
        Rootstock,
        Metis,
        Cronos,
        Null,
        Appchain,
        Superseed,
        Zircuit,
        Morph,
        MantaPacific,
        Hemi,
        AnimeChain,
        UnichainSepolia,
        ArenaZTestnet,
        Pyrope,
        Odyssey,
        AnimechainTestnet,
        MantaPacificTestnet,
        LordchainTestnet,
        BitcoinTestnet4,
        Corn,
        HyperEvm,
        Plume,
        Gunz
    }

    /// @dev Mapping of chain enum to name
    mapping(Chains chains => string name) public forks;

    constructor() {
        forks[Chains.Amoy] = "amoy";
        forks[Chains.Holesky] = "holesky";
        forks[Chains.ArbitrumSepolia] = "arbitrum_sepolia";
        forks[Chains.SolanaDevnet] = "solana_devnet";
        forks[Chains.DeBankTestnet] = "debank_testnet";
        forks[Chains.MantaTestnet] = "manta_testnet";
        forks[Chains.Barret] = "barret";
        forks[Chains.ZkSyncSepolia] = "zksync_sepolia";
        forks[Chains.AlignTestnetV2] = "align_testnet_v2";
        forks[Chains.ModeTestnet] = "mode_testnet";
        forks[Chains.Bob] = "bob";
        forks[Chains.Goerli] = "goerli";
        forks[Chains.GinTestnet] = "gin_testnet";
        forks[Chains.FrameTestnet] = "frame_testnet";
        forks[Chains.BlastSepolia] = "blast_sepolia";
        forks[Chains.AstarZkyoto] = "astar_zkyoto";
        forks[Chains.Hypr] = "hypr";
        forks[Chains.Hekla] = "hekla";
        forks[Chains.OpSepolia] = "op_sepolia";
        forks[Chains.Garnet] = "garnet";
        forks[Chains.Ancient8CelestiaTestnet] = "ancient8_celestia_testnet";
        forks[Chains.Atlas] = "atlas";
        forks[Chains.B3] = "b3";
        forks[Chains.ZoraSepolia] = "zora_sepolia";
        forks[Chains.FunkiTestnet] = "funki_testnet";
        forks[Chains.LiskSepolia] = "lisk_sepolia";
        forks[Chains.Cloud] = "cloud";
        forks[Chains.Game7Testnet] = "game7_testnet";
        forks[Chains.ShapeSepolia] = "shape_sepolia";
        forks[Chains.ArbitrumBlueberry] = "arbitrum_blueberry";
        forks[Chains.MIntegrationsTestnet] = "m_integrations_testnet";
        forks[Chains.Sepolia] = "sepolia";
        forks[Chains.Memecoin2] = "memecoin_2";
        forks[Chains.BaseSepolia] = "base_sepolia";
        forks[Chains.Redstone] = "redstone";
        forks[Chains.Rari] = "rari";
        forks[Chains.ZkSync] = "zksync";
        forks[Chains.Degen] = "degen";
        forks[Chains.Linea] = "linea";
        forks[Chains.Avalanche] = "avalanche";
        forks[Chains.Zora] = "zora";
        forks[Chains.Polygon] = "polygon";
        forks[Chains.Ancient8] = "ancient8";
        forks[Chains.Xai] = "xai";
        forks[Chains.AstarZkevm] = "astar_zkevm";
        forks[Chains.Mode] = "mode";
        forks[Chains.Gnosis] = "gnosis";
        forks[Chains.Blast] = "blast";
        forks[Chains.Apex] = "apex";
        forks[Chains.Funki] = "funki";
        forks[Chains.Lisk] = "lisk";
        forks[Chains.Ham] = "ham";
        forks[Chains.OnchainPoints] = "onchain_points";
        forks[Chains.PolygonZkevm] = "polygon_zkevm";
        forks[Chains.ArbitrumNova] = "arbitrum_nova";
        forks[Chains.Taiko] = "taiko";
        forks[Chains.Boba] = "boba";
        forks[Chains.Cyber] = "cyber";
        forks[Chains.Arbitrum] = "arbitrum";
        forks[Chains.Scroll] = "scroll";
        forks[Chains.Mainnet] = "mainnet";
        forks[Chains.Bsc] = "bsc";
        forks[Chains.Base] = "base";
        forks[Chains.Mint] = "mint";
        forks[Chains.Optimism] = "optimism";
        forks[Chains.Boss] = "boss";
        forks[Chains.BobTestnet] = "bob_testnet";
        forks[Chains.B3Sepolia] = "b3_sepolia";
        forks[Chains.Creator] = "creator";
        forks[Chains.PopCloudTestnet] = "pop_cloud_testnet";
        forks[Chains.Secret] = "secret";
        forks[Chains.Mobl3Testnet] = "mobl3_testnet";
        forks[Chains.AllegedJadeLoon] = "alleged_jade_loon";
        forks[Chains.Kekchain] = "kekchain";
        forks[Chains.EclipseTestnet] = "eclipse_testnet";
        forks[Chains.ZeroTestnet] = "zero_testnet";
        forks[Chains.ApeChain] = "apechain";
        forks[Chains.UniChain] = "unichain";
        forks[Chains.Mantle] = "mantle";
        forks[Chains.BeraChain] = "berachain";
        forks[Chains.Celo] = "celo";
        forks[Chains.Soneium] = "soneium";
        forks[Chains.Sonic] = "sonic";
        forks[Chains.Shape] = "shape";
        forks[Chains.Worldchain] = "worldchain";
        forks[Chains.Flow] = "flow";
        forks[Chains.Sei] = "sei";
        forks[Chains.Perennial] = "perennial";
        forks[Chains.Story] = "story";
        forks[Chains.Gravity] = "gravity";
        forks[Chains.Swellchain] = "swellchain";
        forks[Chains.Sanko] = "sanko";
        forks[Chains.Game7] = "game7";
        forks[Chains.Hychain] = "hychain";
        forks[Chains.Echos] = "echos";
        forks[Chains.Powerloom] = "powerloom";
        forks[Chains.ArenaZ] = "arena_z";
        forks[Chains.Superposition] = "superposition";
        forks[Chains.Ink] = "ink";
        forks[Chains.Forma] = "forma";
        forks[Chains.Eclipse] = "eclipse";
        forks[Chains.Ronin] = "ronin";
        forks[Chains.Rootstock] = "rootstock";
        forks[Chains.Metis] = "metis";
        forks[Chains.Cronos] = "cronos";
        forks[Chains.Appchain] = "appchain";
        forks[Chains.Superseed] = "superseed";
        forks[Chains.Zircuit] = "zircuit";
        forks[Chains.Morph] = "morph";
        forks[Chains.MantaPacific] = "manta_pacific";
        forks[Chains.Hemi] = "hemi";
        forks[Chains.AnimeChain] = "anime_chain";
        forks[Chains.UnichainSepolia] = "unichain_sepolia";
        forks[Chains.ArenaZTestnet] = "arena_z_testnet";
        forks[Chains.Pyrope] = "pyrope";
        forks[Chains.Odyssey] = "odyssey";
        forks[Chains.AnimechainTestnet] = "animechain_testnet";
        forks[Chains.MantaPacificTestnet] = "manta_pacific_testnet";
        forks[Chains.LordchainTestnet] = "lordchain_testnet";
        forks[Chains.BitcoinTestnet4] = "bitcoin_testnet4";
        forks[Chains.Corn] = "corn";
        forks[Chains.HyperEvm] = "hyperevm";
        forks[Chains.Plume] = "plume";
        forks[Chains.Gunz] = "gunz";
    }

    function createFork(Chains chain) public {
        vm.createFork(forks[chain]);
    }

    function createSelectFork(Chains chain) public {
        vm.createSelectFork(forks[chain]);
    }
}

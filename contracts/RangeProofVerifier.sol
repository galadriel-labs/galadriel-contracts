pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import './library/BN128.sol';
import './PublicParams.sol';
import './IPVerifier.sol';

contract RangeProofVerifier {
    using BN128 for BN128.G1Point;
    using BN128 for uint256;

    // inner product verifier.
    IPVerifier public ipVerifier;

    struct Params {
        BN128.G1Point[] gv;
        BN128.G1Point[] hv;
        BN128.G1Point g;
        BN128.G1Point h;
        BN128.G1Point u;
    }

    // range proof.
    struct RangeProof {
        BN128.G1Point A;
        BN128.G1Point S;
        BN128.G1Point T1;
        BN128.G1Point T2;
        uint256 t;
        uint256 txx;
        uint256 u;
        IPProof ipProof;
    }

    // ip proof.
    struct IPProof {
        BN128.G1Point[] l;
        BN128.G1Point[] r;
        uint256 a;
        uint256 b;
    }

    // struct for tmp calculation.
    struct Board {
        uint256 size;
        // to call ip verifier.
        uint256[] gvs;
        uint256[] hvs;
        uint256[] ls;
        uint256[] rs;
        BN128.G1Point tmp;
        uint256 x;
        uint256 x2;
        uint256 y;
        uint256[] yn;
        uint256[] ynInverse;
        uint256 z;
        uint256 zSquare;
        uint256 zNeg;
        uint256[] n2;
        BN128.G1Point[] hPrime;
        BN128.G1Point expect;
        BN128.G1Point actual;
        uint256 dleta;
        uint256[] exp;
        uint256[] challenges;
        uint256[] challengesInverse;
        uint256[] challengesSquare;
        uint256[] challengesSquareInverse;
        uint256[] l;
        uint256[] tl;
        uint256[] r;
        uint256[] tr;
        uint256[] ll;
        uint256[] rr;
    }

    constructor(address ip) {
        ipVerifier = IPVerifier(ip);
    }

    /*
     * @dev normal verify
     */
    function verify(
        Params memory params,
        BN128.G1Point memory v,
        RangeProof memory rangeProof
    ) public view returns (bool) {
        Board memory board;
        board.size = params.gv.length;
        // compute challenge.
        board.y = computeChallenge(rangeProof.A.X, rangeProof.A.Y, rangeProof.S.X, rangeProof.S.Y);

        board.z = computeChallenge(rangeProof.S.X, rangeProof.S.Y, rangeProof.A.X, rangeProof.A.Y);
        board.yn = powers(board.y, board.size);
        board.zNeg = board.z.neg();
        board.zSquare = board.z.mul(board.z).mod();
        board.n2 = powers(2, board.size);
        board.hPrime = hadamard(params.hv, powers(board.y.inv(), board.size));

        board.x = computeChallenge(rangeProof.T1.X, rangeProof.T1.Y, rangeProof.T2.X, rangeProof.T2.Y);
        board.x2 = board.x.mul(board.x);

        // check g*tx + h*t ?= v*z^2 + g*dleta + T1*x + T2*x^2.
        board.expect = v.mul(board.zSquare).add(rangeProof.T1.mul(board.x)).add(rangeProof.T2.mul(board.x2));
        // delta = (z - z^2) * <1^n, y^n> - z^3 * <1^n, 2^n>.
        board.dleta = board.z.sub(board.zSquare).mul(sum(board.yn)).sub(board.zSquare.mul(board.z).mul(sum(board.n2)));
        board.expect = board.expect.add(params.g.mul(board.dleta));
        board.actual = params.g.mul(rangeProof.t).add(params.h.mul(rangeProof.txx));
        if (board.expect.X != board.actual.X || board.expect.Y != board.actual.Y) {
            return false;
        }

        // compute p point. p = A + S*x + gv*-z + h'*(z*y^n + z^2 * 2^n).
        BN128.G1Point memory p = rangeProof.A.add(rangeProof.S.mul(board.x));
        p = p.add(sumVector(params.gv).mul(board.zNeg));
        board.exp = addFieldVector(times(board.yn, board.z), times(board.n2, board.zSquare));
        p = p.add(commit(board.hPrime, board.exp));
        // compute p'. p' = p - h*u. == g*l + h'*r.(this could be apply on inner product).
        p = p.add(params.h.mul(rangeProof.u).neg());

        params.hv = board.hPrime;

        return verifyIPInternal(params, p, rangeProof);
    }

    function optimizedVerify(
        Params memory params,
        BN128.G1Point memory v,
        RangeProof memory rangeProof
    ) public view returns (bool) {
        Board memory board;
        board.size = params.gv.length;

        // compute
        board.y = computeChallenge(rangeProof.A.X, rangeProof.A.Y, rangeProof.S.X, rangeProof.S.Y);
        board.z = computeChallenge(rangeProof.S.X, rangeProof.S.Y, rangeProof.A.X, rangeProof.A.Y);
        board.yn = powers(board.y, board.size);
        board.ynInverse = powers(board.y.inv(), board.size);
        board.zNeg = board.z.neg();
        board.zSquare = board.z.mul(board.z).mod();
        board.n2 = powers(2, board.size);
        // 9 mul, 6 add.
        board.x = computeChallenge(rangeProof.T1.X, rangeProof.T1.Y, rangeProof.T2.X, rangeProof.T2.Y);
        board.x2 = board.x.mul(board.x);

        // check g*tx + h*t ?= v*z^2 + g*dleta + T1*x + T2*x^2.
        // check g*(tx-dleta) + h*t ?= v*z^2 + T1*x + T2*x^2.
        board.expect = v.mul(board.zSquare).add(rangeProof.T1.mul(board.x)).add(rangeProof.T2.mul(board.x2));
        // delta = (z - z^2) * <1^n, y^n> - z^3 * <1^n, 2^n>.
        board.dleta = board.z.sub(board.zSquare).mul(sum(board.yn)).sub(board.zSquare.mul(board.z).mul(sum(board.n2)));
        board.actual = params.g.mul(rangeProof.t.sub(board.dleta)).add(params.h.mul(rangeProof.txx));
        if (board.expect.X != board.actual.X || board.expect.Y != board.actual.Y) {
            return false;
        }

        // 1 add, 1 mul.
        BN128.G1Point memory p;
        p = rangeProof.A.add(rangeProof.S.mul(board.x));

        // compute formula on the right.
        // compute p + li * xi^2 + ri * xi^-2.
        // n*2 mul, n*2 add.
        board.challenges = new uint256[](rangeProof.ipProof.l.length);
        board.challengesSquare = new uint256[](rangeProof.ipProof.l.length);
        board.challengesSquareInverse = new uint256[](rangeProof.ipProof.l.length);

        for (uint256 i = 0; i < rangeProof.ipProof.l.length; i++) {
            uint256 x = computeChallenge(
                rangeProof.ipProof.l[i].X,
                rangeProof.ipProof.l[i].Y,
                rangeProof.ipProof.r[i].X,
                rangeProof.ipProof.r[i].Y
            );
            board.challenges[i] = x;
            board.challengesSquare[i] = x.mul(x).mod();
            board.challengesSquareInverse[i] = board.challengesSquare[i].inv();

            board.tmp = rangeProof.ipProof.l[i];
            p = p.add(board.tmp.mul(board.challengesSquare[i]));
            board.tmp = rangeProof.ipProof.r[i];
            p = p.add(board.tmp.mul(board.challengesSquareInverse[i]));
        }

        // scalar mul, add.
        board.tl = new uint256[](params.gv.length);
        board.tr = new uint256[](params.gv.length);
        board.l = new uint256[](params.gv.length);
        board.r = new uint256[](params.gv.length);
        for (uint256 i = 0; i < params.gv.length; i++) {
            if (i == 0) {
                for (uint256 j = 0; j < rangeProof.ipProof.l.length; j++) {
                    uint256 tmp = board.challenges[j];
                    if (j == 0) {
                        board.tl[i] = tmp;
                    } else {
                        board.tl[i] = board.tl[i].mul(tmp).mod();
                    }
                }

                board.tr[i] = board.tl[i];
                board.tl[i] = board.tl[i].inv();
            } else {
                // i is start from 0.
                // 5 >= k >= 1.
                uint256 k = getBiggestPos(i, rangeProof.ipProof.l.length);

                // tl, tr should not be changed.
                board.tl[i] = board.tl[i - pow(k - 1)]
                    .mul(board.challengesSquare[rangeProof.ipProof.l.length - k])
                    .mod();
                board.tr[i] = board.tr[i - pow(k - 1)]
                    .mul(board.challengesSquareInverse[rangeProof.ipProof.l.length - k])
                    .mod();
            }

            board.l[i] = board.tl[i];

            // set si and si^-1.
            board.r[i] = board.tr[i];

            board.l[i] = board.l[i].mul(rangeProof.ipProof.a).add(board.z);
            board.r[i] = board.r[i].mul(rangeProof.ipProof.b);
            board.r[i] = board.r[i].sub(board.zSquare.mul(board.n2[i]));
            board.r[i] = board.r[i].mul(board.ynInverse[i]).sub(board.z);
        }

        uint256 xu = uint256(keccak256(abi.encodePacked(rangeProof.t))).mod();

        board.actual = commit(params.gv, board.l)
            .add(commit(params.hv, board.r))
            .add(params.u.mul(xu.mul(rangeProof.ipProof.a.mul(rangeProof.ipProof.b).sub(rangeProof.t))))
            .add(params.h.mul(rangeProof.u));

        // return true;
        return board.actual.X == p.X && board.actual.Y == p.Y;
    }

    function pow(uint256 kk) internal pure returns (uint256) {
        uint256 i = kk;
        if (i == 0) {
            return 1;
        }
        uint256 res = 1;
        while (i > 0) {
            res = res * 2;
            i--;
        }

        return res;
    }

    function verifyIPInternal(
        Params memory params,
        BN128.G1Point memory p,
        RangeProof memory rangeProof
    ) internal view returns (bool) {
        Board memory b;
        b.gvs = toUintArray(params.gv);
        b.hvs = toUintArray(params.hv);
        uint256[2] memory pp;
        pp[0] = p.X;
        pp[1] = p.Y;
        uint256[2] memory u;
        u[0] = params.u.X;
        u[1] = params.u.Y;

        //
        b.ll = new uint256[](rangeProof.ipProof.l.length * 2);
        b.rr = new uint256[](rangeProof.ipProof.l.length * 2);
        for (uint256 i = 0; i < rangeProof.ipProof.l.length; i++) {
            b.ll[2 * i] = rangeProof.ipProof.l[i].X;
            b.ll[2 * i + 1] = rangeProof.ipProof.l[i].Y;
            b.rr[2 * i] = rangeProof.ipProof.r[i].X;
            b.rr[2 * i + 1] = rangeProof.ipProof.r[i].Y;
        }

        return
            ipVerifier.optimizedVerifyIPProof(
                b.gvs,
                b.hvs,
                pp,
                u,
                rangeProof.t,
                b.ll,
                b.rr,
                rangeProof.ipProof.a,
                rangeProof.ipProof.b
            );
    }

    function computeChallenge(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(a, b, c, d))).mod();
    }

    /*
     * @dev compute [1, base, base^2, ... , base^(bitSize-1)]
     */
    function powers(uint256 base, uint256 bitSize) internal pure returns (uint256[] memory) {
        uint256[] memory powersRes = new uint256[](bitSize);
        powersRes[0] = 1;
        powersRes[1] = base;
        for (uint256 i = 2; i < bitSize; i++) {
            powersRes[i] = powersRes[i - 1].mul(base).mod();
        }

        return powersRes;
    }

    /*
     * @dev sum []
     */
    function sum(uint256[] memory data) internal pure returns (uint256) {
        uint256 res = data[0];
        for (uint256 i = 1; i < data.length; i++) {
            res = res.add(data[i]);
        }

        return res;
    }

    /*
     * @dev modInverse return (a1.inv, a2.inv, ..., an.inv)
     */
    function modInverse(uint256[] memory a) internal pure returns (uint256[] memory) {
        uint256[] memory res = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; i++) {
            res[i] = a[i].inv();
        }

        return res;
    }

    /*
     * @dev hadamard compute (h1, h2, ..., hn) * (a1, a2, ..., an) = (h1*a1, h2*a2, ..., hn*an)
     */
    function hadamard(BN128.G1Point[] memory m, uint256[] memory a) internal view returns (BN128.G1Point[] memory) {
        BN128.G1Point[] memory res = new BN128.G1Point[](m.length);
        for (uint256 i = 0; i < m.length; i++) {
            res[i] = m[i].mul(a[i]);
        }

        return res;
    }

    /*
     * @dev sum vector.
     */
    function sumVector(BN128.G1Point[] memory v) internal view returns (BN128.G1Point memory) {
        BN128.G1Point memory res = v[0];
        for (uint256 i = 1; i < v.length; i++) {
            res = res.add(v[i]);
        }

        return res;
    }

    /*
     * @dev commit compute (h1, h2, ..., hn) * (a1, a2, ..., an) == h1*a1 + h2*a2 + ... + hn*an.
     * @dev bitSize mul, bitSize-1 add.
     */
    function commit(BN128.G1Point[] memory vector, uint256[] memory scalar)
        internal
        view
        returns (BN128.G1Point memory)
    {
        BN128.G1Point memory res = vector[0].mul(scalar[0]);
        for (uint256 i = 1; i < vector.length; i++) {
            res = res.add(vector[i].mul(scalar[i]));
        }

        return res;
    }

    /*
     * @dev (m1, m2, ..., mn) * scalar == (m1*scalar, m2*scalar, ..., mn*scalar)
     */
    function times(uint256[] memory m, uint256 scalar) internal pure returns (uint256[] memory) {
        uint256[] memory res = new uint256[](m.length);
        for (uint256 i = 0; i < m.length; i++) {
            res[i] = m[i].mul(scalar);
        }

        return res;
    }

    /*
     * @dev add field vector(a1, ..., an) + (b1, ..., bn) == (a1+b1, ..., an+bn)
     */
    function addFieldVector(uint256[] memory a, uint256[] memory b) internal pure returns (uint256[] memory) {
        uint256[] memory res = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; i++) {
            res[i] = a[i].add(b[i]);
        }

        return res;
    }

    /*
     *
     */
    function subFieldVector(uint256[] memory a, uint256[] memory b) internal pure returns (uint256[] memory) {
        uint256[] memory res = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; i++) {
            res[i] = a[i].add(b[i].neg());
        }

        return res;
    }

    function getBiggestPos(uint256 i, uint256 s) internal pure returns (uint256) {
        uint256 l = 1 << s;
        uint256 calTimes;
        while (i < l && l > 0) {
            l = l >> 1;
            calTimes++;
        }
        return 1 + s - calTimes;
    }

    /*
     *
     */
    function multFieldVector(uint256[] memory a, uint256[] memory b) internal pure returns (uint256[] memory) {
        uint256[] memory res = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; i++) {
            res[i] = a[i].mul(b[i]);
        }

        return res;
    }

    function smallParseBinary(
        uint256 t,
        uint256 j,
        uint256 size
    ) internal pure returns (bool) {
        uint256 w = 1 << (size - 1);

        for (uint256 i = 0; i < j; i++) {
            w = w >> 1;
        }

        if ((t & w) != 0) {
            return true;
        }

        return false;
    }

    function multiExp(BN128.G1Point[] memory base, uint256[] memory exp) internal view returns (BN128.G1Point memory) {
        BN128.G1Point memory res;
        res = base[0].mul(exp[0]);
        for (uint256 i = 1; i < base.length; i++) {
            res = res.add(base[i].mul(exp[i]));
        }

        return res;
    }

    function multiExpInverse(BN128.G1Point[] memory base, uint256[] memory exp)
        internal
        view
        returns (BN128.G1Point memory)
    {
        uint256[] memory expInverse = new uint256[](base.length);
        for (uint256 i = 0; i < base.length; i++) {
            expInverse[i] = exp[i].inv();
        }

        return multiExp(base, expInverse);
    }

    function toUintArray(BN128.G1Point[] memory points) internal pure returns (uint256[] memory) {
        uint256[] memory res = new uint256[](2 * points.length);
        for (uint256 i = 0; i < points.length; i++) {
            res[2 * i] = points[i].X;
            res[2 * i + 1] = points[i].Y;
        }

        return res;
    }
}

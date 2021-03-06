/*
 * pQP.cu
 *
 *      Created on: Feb 27, 2014
 *      Author: Pantelis Sopasakis
 */

/*
 *   pQP - CUDA implementation of the parallel QP algorithm by Brand et al.
 *   Copyright (C) 2014 Pantelis Sopasakis <pantelis.sopasakis@imtlucca.it>
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "pQP.cuh"

static void HandleError(cudaError_t err, const char *file, int line) {
	if (err != cudaSuccess) {
		printf("%s in %s at line %d\n", cudaGetErrorString(err), file, line);
		exit(EXIT_FAILURE);
	}
}
#define HANDLE_CUDA_ERROR( err ) (HandleError( err, __FILE__, __LINE__ ))

int init_matrices(real_t *Q, real_t *h, real_t *V, real_t *W) {
	real_t *Q_init;
	ptrdiff_t i;
	if (Q == NULL) {
		fprintf(stderr, "Uninitialized matrix (Q) at line %d of %s\n", __LINE__,
				__FILE__);
		return EXIT_FAILURE;
	}
	if (h == NULL) {
		fprintf(stderr, "Uninitialized matrix (h) at line %d of %s\n", __LINE__,
				__FILE__);
		return EXIT_FAILURE;
	}
	if (V == NULL) {
		fprintf(stderr, "Uninitialized matrix (V) at line %d of %s\n", __LINE__,
				__FILE__);
		return EXIT_FAILURE;
	}
	if (W == NULL) {
		fprintf(stderr, "Uninitialized matrix (W) at line %d of %s\n", __LINE__,
				__FILE__);
		return EXIT_FAILURE;
	}
	Q_init = (real_t *) malloc(N * N * sizeof(*Q_init));
	/* Initialize Q with random data */
	srand(1001L);
	//srand(time(NULL)); // random seed (time-based)
	for (i = 0; i < N * N; i++) {
		Q_init[i] = (real_t) ((2 * rand() - RAND_MAX) % 1000 + 1) / 1000.0;
	}
	cblas_dgemm(CblasColMajor, CblasTrans, CblasNoTrans, N, N, N, 1.0, Q_init,
			N, Q_init, N, 0.0, Q, N);
	for (i = 0; i < N; i++) {
		Q[i * (N + 1)] += 2.0 * N;
		h[i] = (real_t) ((2 * rand() - RAND_MAX) % 1000 + 1) / 1000.0;
		V[i * (2 * N + 1)] = 1;
		V[i * (2 * N + 1) + N] = -1;
		W[i] = 10.0;
		W[i + N] = -9.0;
	}
	free(Q_init);
	return EXIT_SUCCESS;
}

template<typename T> void print_matrix(char* desc, int matrix_order,
		int transpose, lapack_int n_rows, lapack_int n_columns, T *a) {
	lapack_int i;
	lapack_int j;
	lapack_int lda = LAPACK_COL_MAJOR == matrix_order ? n_rows : n_columns;
	printf("\n %s\n", desc);
	for (i = 0; i < (transpose == 0 ? n_rows : n_columns); i++) {
		for (j = 0; j < (transpose == 0 ? n_columns : n_rows); j++) {
			if (LAPACK_COL_MAJOR == matrix_order) {
				printf(" %10.8f\t",
						(double) a[(transpose == 0 ? j * lda + i : i * lda + j)]);
			} else if (LAPACK_ROW_MAJOR) {
				printf(" %10.8f\t", (double) a[i * lda + j]);
			}
		}
		printf("\n");
	}
}

template<typename T> void copy_as_transpose(T *dest, T *source,
		const int n_rows_source, const int n_cols_source) {
	int i;
	int j;
	for (i = 0; i < n_rows_source; i++) {
		for (j = 0; j < n_cols_source; j++) {
			dest[j * n_rows_source + i] = source[i * n_cols_source + j];
		}
	}
}

static void HANDLE_ALLOCATION_ERROR(void* x, char* error_code) {
	// If x is NULL (after dynamic allocation), throw an error and exit
	if (x == NULL) {
		fprintf(stderr, "Allocation error: %s\n", error_code);
		exit(305);
	}
}

int main(void) {

	/* Declarations on HOST */
	double *Q = NULL;
	double *Q_copy_1 = NULL;
	double *h = NULL;
	double *V = NULL;
	double *W = NULL;
	double *Y = NULL; // Y = Q\V'
	double *z = NULL; // z = Q\h
	double *Q_tilde = NULL;
	double *h_tilde = NULL;
	/* Declarations on DEVICE */
	double *Q_tilde_dev = NULL;
	double *h_tilde_dev = NULL;
	/* Aux variables on HOST */lapack_int ipiv[N];
	lapack_int info;
	/* End of Declarations */

	/* Allocations on the host */
	Q = (double *) malloc(N * N * sizeof(*Q));
	HANDLE_ALLOCATION_ERROR(Q, "Q");
	Q_copy_1 = (double *) malloc(N * N * sizeof(*Q));
	HANDLE_ALLOCATION_ERROR(Q_copy_1, "Q_copy_1");
	h = (double *) malloc(N * sizeof(*h));
	HANDLE_ALLOCATION_ERROR(h, "h");
	V = (double *) malloc(2 * N * N * sizeof(*V));
	HANDLE_ALLOCATION_ERROR(V, "V");
	W = (double *) malloc(2 * N * sizeof(*W));
	HANDLE_ALLOCATION_ERROR(W, "W");
	Y = (double *) malloc(2 * N * N * sizeof(*Y));
	HANDLE_ALLOCATION_ERROR(Y, "Y");
	z = (double *) malloc(N * sizeof(*z));
	HANDLE_ALLOCATION_ERROR(z, "z");
	Q_tilde = (double *) malloc((2 * N) * (2 * N) * sizeof(*Q_tilde));
	HANDLE_ALLOCATION_ERROR(Q_tilde, "Q_tilde");
	h_tilde = (double *) malloc(2 * N * sizeof(*h_tilde));
	HANDLE_ALLOCATION_ERROR(h_tilde, "h_tilde");

	/* Initialize Matrices Q, h, V and W with random data */
	init_matrices(Q, h, V, W);

	/***************************/
	/*         PART A          */
	/***************************/
	memcpy(z, h, N * sizeof(*z)); // z <-- h
	memcpy(Q_copy_1, Q, N * N * sizeof(*Q)); // Q_copy_1 <-- Q
	info = LAPACKE_dgesv(LAPACK_COL_MAJOR, N, 1, Q_copy_1, N, ipiv, z, N); // z <-- Q^{-1}z
	printf("\ninfo2 = %d, %s\n", info, info == 0 ? "success!" : "failure");
	memcpy(h_tilde, W, 2 * N * sizeof(*h_tilde)); // h_tilde <-- W
	cblas_dgemv(CblasColMajor, CblasNoTrans, 2 * N, N, 1.0, V, 2 * N, z, 1, 1.0,
			h_tilde, 1); // htilde <-- htilde + V*z
	free(Q_copy_1);

	/***************************/
	/*         PART B          */
	/***************************/
	copy_as_transpose<double>(Y, V, N, 2 * N); // Y <-- V'

//	print_matrix<double>("V'", LAPACK_COL_MAJOR, 1, 2 * N, N, V);
//	print_matrix("Q", LAPACK_COL_MAJOR, 0, N, N, Q);

//  See also: http://www.netlib.org/lapack/explore-html/d3/d8c/dsgesv_8f.html
//	lapack_int LAPACKE_dgesv( int matrix_order, lapack_int n, lapack_int nrhs,
//	                          double* a, lapack_int lda, lapack_int* ipiv,
//	                          double* b, lapack_int ldb );
	info = LAPACKE_dgesv(LAPACK_COL_MAJOR, N, 2 * N, Q, N, ipiv, Y, N);
	printf("\ninfo = %d, %s\n", info, info == 0 ? "success!" : "failure");

//	print_matrix<double>("Y=Q\\V'", LAPACK_COL_MAJOR, 0, N, 2 * N, Y);

	// Documentation:
	// https://developer.apple.com/library/mac/documentation/Accelerate/Reference/BLAS_Ref/Reference/reference.html
	cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans, 2 * N, 2 * N, N, 1.0,
			V, 2 * N, Y, N, 0.0, Q_tilde, 2 * N);

	print_matrix<double>("Qtilde", LAPACK_COL_MAJOR, 0, 2 * N, 2 * N, Q_tilde);
	/* Here Y = Q\V */

	/***************************/
	/*         PART C          */
	/***************************/
	// Parallel Implementation (CUDA)
	/* Allocate memory on DEVICE for Q_tilde_dev */
	HANDLE_CUDA_ERROR(
			cudaMalloc((void **) &Q_tilde_dev, (2 * N) * (2 * N) * sizeof(*Q_tilde_dev)));
	/* Allocate memory on DEVICE for h_tilde_dev */
	HANDLE_CUDA_ERROR(
			cudaMalloc((void **) &h_tilde_dev, (2 * N) * sizeof(*h_tilde_dev)));

	return 0;
}

#include <mbedtls/version.h>
#include <mbedtls/x509_crt.h>
#include <psa/crypto.h>

int main(void)
{
    mbedtls_x509_crt certificate;
    mbedtls_x509_crt_init(&certificate);
    mbedtls_x509_crt_free(&certificate);

    return psa_crypto_init() == PSA_SUCCESS &&
           mbedtls_version_get_number() != 0 ? 0 : 1;
}
